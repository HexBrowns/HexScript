--[[
EffectUtils_Lowpoly.lua

ローポリ系スクリプト（@ローポリ化.anm2 / @ローポリ背景.obj2）の共有モジュール。

@通常 セクション向け:
  ジッター格子の点生成 → Bowyer-Watson Delaunay → cbuffer バッチ詰め。
  メッシュはパラメータをキーにメモ化するので、アニメ OFF なら再計算は初回のみ。

@高速 セクション向け:
  grid_params() だけを使う。三角形分割・色計算は全て HLSL 側で完結するため、
  CPU 側は格子の歩幅とジッター量をシェーダーへ渡すだけ。

drawpoly は使わない（後続フィルタを維持するため）。
全面 CPU ラスタも obj.getpixeldata も使わない（VRAM 読み戻しは HLSL より遅い）。

色空間（2026-10-13、ローポリ背景 v3.20 / ローポリ化 v3.20）:
  色1→色2 の補間は mix_prepare / mix_at（EffectUtils_ColorSpace の mix_values）。
  sRGB（0）のときは mix_prepare が nil を返し、今までと同じ lerp を通る。
  ばらつき（apply_hsv_jitter）は space に 7 を渡すと Oklch の h・C・L を揺らす。
  省略・3 のときは今までと同じ HSV。color_at の引数は末尾に足しただけで、今までの呼び方はそのまま通る。
  検証器: AI/scripts/ローポリ/verify_colorspace_ext.py

グーロー（2026-10-15、ローポリ背景 v3.40 / ローポリ化 v3.40）:
  build_tri_records_vertex / append_tri_list4 / GOURAUD_BATCH を足した（頂点ごとの値を 1 三角形 4 float4 で渡す）。
  既存の関数は変えていない。検証器: AI/scripts/ローポリ/verify_gouraud.py
]]

local EffectUtils_Lowpoly = {}

local bit = bit or require("bit")
local bit_band = bit.band
local bit_bxor = bit.bxor
local bit_rshift = bit.rshift
local bit_lshift = bit.lshift
local bit_tobit = bit.tobit
local math_floor = math.floor
local math_ceil = math.ceil
local math_max = math.max
local math_min = math.min
local math_abs = math.abs
local math_sin = math.sin
local math_cos = math.cos
local math_sqrt = math.sqrt
local math_pi = math.pi

-- Delaunay を CPU で回す @通常 セクションの点数上限。
-- Bowyer-Watson は bad triangle 探索が線形なので、ここを上げると急激に重くなる。
local MAX_POINTS = 2200

-- 1 パスあたりの三角形数。cbuffer は 3 float4/三角形 + ヘッダー。
-- 256 なら 775 float4 (約 12KB) で D3D11 の 64KB 上限に十分収まる。
local BATCH_SIZE = 256

local MESH_CACHE_MAX = 4

-- Oklch のばらつきで「彩度変化 ±100%」に当てる C の幅。sRGB で最も鮮やかな色の C（マゼンタ約 0.32）に合わせ、
-- HSV の S（0〜1）を ±100% 動かすのと同じくらいの振れ幅にする。HLSL 側の LP_OKLCH_C_REF と同じ値
local OKLCH_C_REF = 0.32

-- EffectUtils_ColorSpace は sRGB 以外を選んだときだけ読む（既定の計算は読まずに済む）
local colorspace_mod = nil
local colorspace_warned = false
local function colorspace()
  if colorspace_mod == nil then
    local ok, m = pcall(require, "EffectUtils_ColorSpace")
    if ok and type(m) == "table" then
      colorspace_mod = m
    else
      colorspace_mod = false
      if not colorspace_warned then
        colorspace_warned = true
        print("@warn", "[EffectUtils_Lowpoly] EffectUtils_ColorSpace.lua を読めないので sRGB / HSV で計算します")
      end
    end
  end
  return colorspace_mod or nil
end

function EffectUtils_Lowpoly.as_bool(value, default)
  if type(value) == "boolean" then
    return value
  elseif type(value) == "number" then
    return value ~= 0
  elseif value == nil then
    return default
  end
  return default
end

function EffectUtils_Lowpoly.clamp(v, lo, hi)
  return math_max(lo, math_min(hi, v))
end

local function clamp(v, lo, hi)
  return math_max(lo, math_min(hi, v))
end

--- 32bit 整数の下位 32bit だけの乗算。倍精度で厳密に扱える 16bit ずつに割る。
local function mul32(a, b)
  local a0 = bit_band(a, 0xffff)
  local a1 = bit_band(bit_rshift(a, 16), 0xffff)
  local b0 = bit_band(b, 0xffff)
  local b1 = bit_band(bit_rshift(b, 16), 0xffff)
  -- a0*b0 は 2^32 未満、a0*b1 + a1*b0 は 2^33 未満。どちらも倍精度で厳密
  return bit_tobit(a0 * b0 + bit_lshift(bit_band(a0 * b1 + a1 * b0, 0xffff), 16))
end

--- PCG の出力関数（XSH-RR 系）。入力 1bit の違いが出力の約半分のビットに伝わる。
--- @高速 セクションの HLSL 側 pcg_hash と同じ定数。
local function pcg32(v)
  local state = bit_tobit(mul32(v, 747796405) + 2891336453)
  local word = mul32(bit_bxor(bit_rshift(state, bit_rshift(state, 28) + 4), state), 277803737)
  return bit_bxor(bit_rshift(word, 22), word) % 4294967296
end

--- 整数の組から [0,1) の擬似乱数。
---
--- 旧版は `(n * 1103515245 + 12345) % 2147483647` の LCG だったが、2 点でハッシュになっていなかった。
---   1. n が 2^31 近いと積が 2.4e18 = 2^61 に達し、倍精度（仮数 53bit）の下位 8bit が落ちる。
---      残っていた「乱数らしさ」はこの丸め誤差だけだった
---   2. 剰余を取るだけなので ix を 1 増やすと値が必ず一定量ずれる**等差数列**になる
---      （実測: ix 方向の階差 400 件が 45 種類しかなく、最頻値 0.636702 が 32 回）
--- 結果として、色相・彩度・明度の 3 チャンネルが定数差の関係で連動し（corr(色相,明度)=0.74）、
--- ジッターの ox / oy も連動していた。極端値が同じ三角形に重なるため、
--- 周囲から浮いた三角形が生まれる。
--- 検証器: AI/scripts/ローポリ/verify_lowpoly.py
local function hash21(ix, iy, seed)
  -- 入力を 20bit に畳んでから足す（項の最大 1.03e15、3 項で 3.1e15 と 2^53 に収まる）
  local n = (math_floor(ix) % 1048576) * 374761393
          + (math_floor(iy) % 1048576) * 668265263
          + (math_floor(seed or 0) % 1048576) * 982451653
  return pcg32(n % 4294967296) / 4294967296
end

function EffectUtils_Lowpoly.hash21(ix, iy, seed)
  return hash21(ix, iy, seed or 0)
end

function EffectUtils_Lowpoly.color_to_rgb01(col)
  local r = bit.band(bit.rshift(col, 16), 0xff) / 255
  local g = bit.band(bit.rshift(col, 8), 0xff) / 255
  local b = bit.band(col, 0xff) / 255
  return r, g, b
end

function EffectUtils_Lowpoly.rgb_to_hsv(r, g, b)
  local maxc = math_max(r, g, b)
  local minc = math_min(r, g, b)
  local d = maxc - minc
  local h = 0
  if d > 1e-8 then
    if maxc == r then
      h = ((g - b) / d) % 6
    elseif maxc == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h / 6
    if h < 0 then h = h + 1 end
  end
  local s = maxc > 1e-8 and (d / maxc) or 0
  return h, s, maxc
end

function EffectUtils_Lowpoly.hsv_to_rgb(h, s, v)
  local i = math_floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then return v, t, p end
  if i == 1 then return q, v, p end
  if i == 2 then return p, v, t end
  if i == 3 then return p, q, v end
  if i == 4 then return t, p, v end
  return v, p, q
end

-- 格子とセル ------------------------------------------------------------

--- nx*ny <= max_points を満たす最小のセル幅を解析的に求める。
--- 旧実装は cell += 4 の線形探索だったため着地点が開始値に依存し、
--- 「セルサイズを下げると逆に粗くなる」非単調な挙動になっていた。
--- (w/c+1)*(h/c+1) <= P を c について解く（floor で減る分は安全側）。
function EffectUtils_Lowpoly.min_cell_for_budget(w, h, max_points)
  max_points = max_points or MAX_POINTS
  if max_points < 4 then max_points = 4 end
  local a = w * h
  if a <= 0 then return 1 end
  local b = w + h
  local disc = b * b - 4 * a * (1 - max_points)
  if disc < 0 then return 1 end
  local u = (-b + math_sqrt(disc)) / (2 * a)
  if u <= 0 then return 1 end
  return math_max(1, math_ceil(1 / u))
end

--- 格子パラメータ。apply_budget=true のとき点数上限に合わせてセルを引き上げる。
--- @高速 セクションは CPU で点を持たないので apply_budget=false（スライダー全域が生きる）。
--- 戻り値: nx, ny, step_x, step_y, max_jit, cell
function EffectUtils_Lowpoly.grid_params(w, h, cell, jitter, apply_budget)
  cell = math_max(cell or 8, 1)
  if apply_budget then
    cell = math_max(cell, EffectUtils_Lowpoly.min_cell_for_budget(w, h))
  end
  local nx = math_max(2, math_floor(w / cell) + 1)
  local ny = math_max(2, math_floor(h / cell) + 1)
  local step_x = w / (nx - 1)
  local step_y = h / (ny - 1)
  local max_jit = 0.45 * math_min(step_x, step_y) * (clamp(jitter or 0, 0, 100) / 100)
  return nx, ny, step_x, step_y, max_jit, cell
end

--- 外周を固定したジッター格子点。phase はオフセットベクトルの回転角（ラジアン）。
function EffectUtils_Lowpoly.build_points(w, h, cell, jitter, seed, phase)
  seed = math_floor(seed or 0)
  phase = phase or 0
  local nx, ny, step_x, step_y, max_jit, real_cell =
    EffectUtils_Lowpoly.grid_params(w, h, cell, jitter, true)

  local points = {}
  local cos_p = math_cos(phase)
  local sin_p = math_sin(phase)

  for iy = 0, ny - 1 do
    for ix = 0, nx - 1 do
      local x = ix * step_x
      local y = iy * step_y
      local on_border = (ix == 0 or iy == 0 or ix == nx - 1 or iy == ny - 1)
      if not on_border and max_jit > 0 then
        local ox = (hash21(ix, iy, seed) - 0.5) * 2
        local oy = (hash21(ix, iy, seed + 91) - 0.5) * 2
        -- オフセットを phase で回転させると、点が円軌道を描くのでループが連続する
        local rx = ox * cos_p - oy * sin_p
        local ry = ox * sin_p + oy * cos_p
        x = x + rx * max_jit
        y = y + ry * max_jit
      end
      points[#points + 1] = { x = clamp(x, 0, w), y = clamp(y, 0, h), ix = ix, iy = iy }
    end
  end
  return points, real_cell, step_x, step_y
end

-- Bowyer-Watson Delaunay -------------------------------------------------

local function dist2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end

local function circumcircle(ax, ay, bx, by, cx, cy)
  local A = bx - ax
  local B = by - ay
  local C = cx - ax
  local D = cy - ay
  local E = A * (ax + bx) + B * (ay + by)
  local F = C * (ax + cx) + D * (ay + cy)
  local G = 2 * (A * (cy - by) - B * (cx - bx))
  if math_abs(G) < 1e-12 then
    return nil
  end
  local cx0 = (D * E - B * F) / G
  local cy0 = (A * F - C * E) / G
  return cx0, cy0, dist2(ax, ay, cx0, cy0)
end

local function orient(ax, ay, bx, by, cx, cy)
  return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

--- 三角形を {i,j,k}（1始まりの点インデックス、CCW）の配列で返す。
---
--- 2026-10-13（ローポリ化 v3.30・強化デバッグ 7.5）: 結果を 1 つも変えずに速くした。
---   旧版は点を 1 つ足すたびに、すべての三角形の外接円を作り直して調べていた（点数の 2 乗。
---   メッシュのアニメでは毎フレーム）。
---   1. 外接円は三角形を作ったときに 1 回だけ計算して持つ（式と引数の順は旧版と同じなので値も同じ）
---   2. この先に足す点の y の最小値（fut_min）より外接円が上にある三角形は、もう「悪い三角形」に
---      なれないので、調べる列（active）から外して done へ移す
---   悪い三角形の並び・境界の辺の並び・新しい三角形の並びは旧版と同じになる（done の三角形は旧版でも
---   悪い三角形にならない）。旧版の tris の並びは「作った順」なので、最後に作った順（seq）で並べ直す。
---   旧版の判定は「外接円の中か」を毎回 circumcircle から求めて dist2(p, 中心) <= r2 * (1 + 1e-10) で見ていた。
---   旧版と同じ結果になることの検査: AI/scripts/ローポリ/verify_speed.py
function EffectUtils_Lowpoly.delaunay(points)
  local n = #points
  if n < 3 then return {} end

  local pts = {}
  for i = 1, n do
    pts[i] = { x = points[i].x, y = points[i].y }
  end

  local min_x, min_y = pts[1].x, pts[1].y
  local max_x, max_y = min_x, min_y
  for i = 2, n do
    local p = pts[i]
    if p.x < min_x then min_x = p.x end
    if p.y < min_y then min_y = p.y end
    if p.x > max_x then max_x = p.x end
    if p.y > max_y then max_y = p.y end
  end
  local dmax = math_max(max_x - min_x, max_y - min_y, 1)
  local midx = (min_x + max_x) * 0.5
  local midy = (min_y + max_y) * 0.5

  local p1, p2, p3 = n + 1, n + 2, n + 3
  pts[p1] = { x = midx - 20 * dmax, y = midy - dmax }
  pts[p2] = { x = midx, y = midy + 20 * dmax }
  pts[p3] = { x = midx + 20 * dmax, y = midy - dmax }

  -- fut_min[i] = 点 i 以降（i を含む）の y の最小値。fut_min[n + 1] は +∞
  local fut_min = {}
  fut_min[n + 1] = math.huge
  for i = n, 1, -1 do
    local y = pts[i].y
    local m = fut_min[i + 1]
    fut_min[i] = (y < m) and y or m
  end

  -- 三角形 {a, b, c, seq = 作った順, cx, cy, r2, rr = 外接円の半径に余裕を足したもの}。
  -- 外接円の無い（3 点が一直線の）三角形は cx = nil（旧版の判定は常に「外」）
  local seq = 0
  local function make_tri(a, b, c)
    seq = seq + 1
    local pa, pb, pc = pts[a], pts[b], pts[c]
    local cx, cy, r2 = circumcircle(pa.x, pa.y, pb.x, pb.y, pc.x, pc.y)
    local rr = nil
    if cx then
      rr = math_sqrt(r2) * (1 + 1e-6) + 1e-6
    end
    return { a, b, c, seq = seq, cx = cx, cy = cy, r2 = r2, rr = rr }
  end

  local active = { make_tri(p1, p2, p3) }
  local done = {}

  local function edge_key(a, b)
    if a > b then a, b = b, a end
    return a * 100000 + b
  end

  for i = 1, n do
    local px, py = pts[i].x, pts[i].y
    local ymin_next = fut_min[i + 1]
    local bad = {}
    local kept = {}
    for ti = 1, #active do
      local t = active[ti]
      local cx = t.cx
      -- 旧版と同じ判定（dist2(px, py, cx, cy) <= r2 * (1 + 1e-10)）
      local inside = false
      if cx then
        local dx, dy = px - cx, py - t.cy
        inside = dx * dx + dy * dy <= t.r2 * (1 + 1e-10)
      end
      if inside then
        bad[#bad + 1] = t
      elseif (not cx) or (ymin_next - t.cy > t.rr) then
        -- この先のどの点も外接円に入らない（y の差だけで半径を超える）。もう調べない
        done[#done + 1] = t
      else
        kept[#kept + 1] = t
      end
    end

    -- bad 三角形の中で1回だけ現れる辺 = 空洞の境界
    local edge_count = {}
    for bi = 1, #bad do
      local t = bad[bi]
      edge_count[edge_key(t[1], t[2])] = (edge_count[edge_key(t[1], t[2])] or 0) + 1
      edge_count[edge_key(t[2], t[3])] = (edge_count[edge_key(t[2], t[3])] or 0) + 1
      edge_count[edge_key(t[3], t[1])] = (edge_count[edge_key(t[3], t[1])] or 0) + 1
    end

    local boundary = {}
    for bi = 1, #bad do
      local t = bad[bi]
      local e = { { t[1], t[2] }, { t[2], t[3] }, { t[3], t[1] } }
      for ei = 1, 3 do
        local a, b = e[ei][1], e[ei][2]
        if edge_count[edge_key(a, b)] == 1 then
          boundary[#boundary + 1] = { a, b }
        end
      end
    end

    active = kept
    for bi = 1, #boundary do
      local a, b = boundary[bi][1], boundary[bi][2]
      -- 新しい点と合わせて CCW にそろえる
      if orient(pts[a].x, pts[a].y, pts[b].x, pts[b].y, px, py) < 0 then
        a, b = b, a
      end
      active[#active + 1] = make_tri(a, b, i)
    end
  end

  -- 旧版の並び（作った順）に戻す
  local all = {}
  for ti = 1, #done do all[#all + 1] = done[ti] end
  for ti = 1, #active do all[#all + 1] = active[ti] end
  table.sort(all, function(u, v) return u.seq < v.seq end)

  local result = {}
  for ti = 1, #all do
    local t = all[ti]
    if t[1] <= n and t[2] <= n and t[3] <= n then
      result[#result + 1] = { t[1], t[2], t[3] }
    end
  end
  return result
end

-- メッシュのメモ化 --------------------------------------------------------

-- require はモジュールをキャッシュするので、この upvalue はフレームをまたいで残る。
-- 複数オブジェクトが別パラメータで同時に使う場合を考えて数エントリ持つ。
local mesh_cache = {}

--- 同一パラメータなら Delaunay を再実行しない。
--- アニメ OFF は phase が 0 固定なので、2フレーム目以降は常にヒットする。
function EffectUtils_Lowpoly.get_mesh(w, h, cell, jitter, seed, phase)
  local key = string.format("%d,%d,%.3f,%.3f,%d,%.6f",
    w, h, cell or 0, jitter or 0, math_floor(seed or 0), phase or 0)
  for i = 1, #mesh_cache do
    if mesh_cache[i].key == key then
      local e = mesh_cache[i]
      if i > 1 then
        table.remove(mesh_cache, i)
        table.insert(mesh_cache, 1, e)
      end
      return e.points, e.tris
    end
  end

  local points = EffectUtils_Lowpoly.build_points(w, h, cell, jitter, seed, phase)
  local tris = EffectUtils_Lowpoly.delaunay(points)
  table.insert(mesh_cache, 1, { key = key, points = points, tris = tris })
  while #mesh_cache > MESH_CACHE_MAX do
    table.remove(mesh_cache)
  end
  return points, tris
end

-- 色 ---------------------------------------------------------------------

--- 三角形ごとの HSV オフセット。hue_phase はラジアン（1周で色相1巡）。
--- 戻り値はそのまま cbuffer へ渡せる加算オフセット（h は 0-1 周期、s/v は 0-1 絶対量）。
function EffectUtils_Lowpoly.hsv_offsets(tri_idx, seed, hue_var, sat_var, val_var, hue_phase, val_phase)
  local hh = hash21(tri_idx, 1, seed + 100)
  local hs = hash21(tri_idx, 2, seed + 200)
  local hv = hash21(tri_idx, 3, seed + 300)
  local hue_off = (hh - 0.5) * 2 * ((hue_var or 0) / 360) + (hue_phase or 0) / (math_pi * 2)
  local sat_off = (hs - 0.5) * 2 * ((sat_var or 0) / 100)
  local val_off = (hv - 0.5) * 2 * ((val_var or 0) / 100)
  if (val_phase or 0) ~= 0 then
    val_off = val_off * math_cos(val_phase)
  end
  return hue_off, sat_off, val_off
end

--- 三角形ごとのばらつき。space: 3 か省略で HSV（今までの計算）、7 で Oklch。
--- Oklch では 色相 → h、彩度 → C（±100% が OKLCH_C_REF）、明度 → Oklab の L を同じオフセットで動かす。
--- sRGB に無い色は EffectUtils_ColorSpace が明るさと色相を保ったまま C を下げて収める。
function EffectUtils_Lowpoly.apply_hsv_jitter(r, g, b, tri_idx, seed, hue_var, sat_var, val_var, hue_phase, val_phase, space)
  hue_var = hue_var or 0
  sat_var = sat_var or 0
  val_var = val_var or 0
  hue_phase = hue_phase or 0
  if hue_var <= 0 and sat_var <= 0 and val_var <= 0 and hue_phase == 0 then
    return r, g, b
  end
  local hue_off, sat_off, val_off =
    EffectUtils_Lowpoly.hsv_offsets(tri_idx, seed, hue_var, sat_var, val_var, hue_phase, val_phase)
  if (space or 3) > 6.5 then
    local cs = colorspace()
    if cs then
      local hh, cc, ll = cs.to_space(r, g, b, 7)
      return cs.from_space((hh + hue_off) % 1, math_max(cc + sat_off * OKLCH_C_REF, 0), clamp(ll + val_off, 0, 1), 7)
    end
  end
  local h, s, v = EffectUtils_Lowpoly.rgb_to_hsv(r, g, b)
  h = (h + hue_off) % 1
  if h < 0 then h = h + 1 end
  s = clamp(s + sat_off, 0, 1)
  v = clamp(v + val_off, 0, 1)
  return EffectUtils_Lowpoly.hsv_to_rgb(h, s, v)
end

--- グラデーション係数 0..1。色のグラデーションと明転の起点で共有する。
function EffectUtils_Lowpoly.gradient_t(cx, cy, w, h, gradient_dir)
  local t
  if gradient_dir < 0.5 then
    t = cy / math_max(h, 1)
  elseif gradient_dir < 1.5 then
    t = cx / math_max(w, 1)
  else
    t = (cx + cy) / math_max(w + h, 1)
  end
  return clamp(t, 0, 1)
end

--- ランダム配色。u は三角形ごとの一様乱数 [0,1)、t は色1→色2の係数。
---   t = saturate((center - u) / blend + 0.5)
--- blend=0 のときは t = (u < center) で、色1か色2のどちらかになる。
--- blend>0 のとき境目が幅 blend のランプになり、中間色が混ざる。
---
--- center は random_mix_center() で決める。u が一様なら t の平均がちょうど ratio になり、
--- ratio=0 / 1 では blend に関わらず単色になる。
--- 単純に center=ratio とすると ratio=0 でも色2寄りの三角形が残り、
--- ratio*(1+blend)-blend/2 とすると平均がずれる（ratio 0.3, blend 1 で 0.18）ため逆算している。
local function random_mix_mean(center, blend)
  local hi = center + blend * 0.5
  local a = clamp(center - blend * 0.5, 0, 1)   -- u < a では t = 1
  local b = clamp(hi, 0, 1)                     -- a <= u < b では t = (hi - u) / blend
  return a + ((hi - a) * (hi - a) - (hi - b) * (hi - b)) / (2 * blend)
end

function EffectUtils_Lowpoly.random_mix_center(ratio, blend)
  ratio = clamp(ratio or 0.5, 0, 1)
  blend = clamp(blend or 0, 0, 1)
  if blend < 1e-4 then
    return ratio
  end
  -- 平均は center について単調増加。フレームに 1 回なので二分法で十分
  local lo, hi = -blend * 0.5, 1 + blend * 0.5
  for _ = 1, 40 do
    local mid = (lo + hi) * 0.5
    if random_mix_mean(mid, blend) < ratio then lo = mid else hi = mid end
  end
  return (lo + hi) * 0.5
end

function EffectUtils_Lowpoly.random_mix_t(u, center, blend)
  blend = clamp(blend or 0, 0, 1)
  if blend < 1e-4 then
    return (u < center) and 1 or 0
  end
  return clamp((center - u) / blend + 0.5, 0, 1)
end

--- 三角形の頂点番号から作る一様乱数。
--- @通常 の三角形番号は Delaunay の出力順で、メッシュアニメ中に入れ替わる。
--- 頂点番号は格子点の並びで固定なので、同じ三角形が残っている間は値が変わらない。
--- hash21 を 1 段で (a*K+b, c) に掛けると、辺を共有する三角形同士で値が逆相関した
--- （隣接の同色率 0.415、独立なら 0.5）。頂点ごとに 1 段ずつ掛けて混ぜると 0.49〜0.51 になる。
--- この逆相関の元は hash21 が等差数列だったことで、2026-09-23 に hash21 側を直した。
--- 3 段の入れ子はその名残だが、PCG の入れ子なので害は無いため残している。
function EffectUtils_Lowpoly.tri_vertex_hash(tri, salt, seed)
  local a, b, c = tri[1], tri[2], tri[3]
  if a > b then a, b = b, a end
  if b > c then b, c = c, b end
  if a > b then a, b = b, a end
  salt = salt or 0
  seed = seed or 0
  local u = hash21(a, b, seed + salt)
  u = hash21(math_floor(u * 1000003), c, seed + salt + 1)
  return hash21(math_floor(u * 1000003), salt, seed + 2)
end

--- 色1→色2 の補間の準備。space は色空間の番号（EffectUtils_ColorSpace と同じ）、hue_long は 1 で長経路。
--- sRGB（0）なら nil を返す（color_at は今までと同じ lerp を通る）。
--- 戻り値の x1..z2 は色空間の値で、@高速 はこれをそのまま cbuffer へ渡す。
function EffectUtils_Lowpoly.mix_prepare(r1, g1, b1, r2, g2, b2, space, hue_long)
  space = math_floor(tonumber(space) or 0)
  if space <= 0 then
    return nil
  end
  local cs = colorspace()
  if not cs then
    return nil
  end
  local x1, y1, z1 = cs.to_space(r1, g1, b1, space)
  local x2, y2, z2 = cs.to_space(r2, g2, b2, space)
  return {
    space = space, hue_long = (tonumber(hue_long) or 0) > 0.5, cs = cs,
    x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2,
  }
end

--- mix_prepare した 2 色の t（0..1）の色を sRGB で返す。
function EffectUtils_Lowpoly.mix_at(mix, t)
  local cs = mix.cs
  local x, y, z = cs.mix_values(mix.x1, mix.y1, mix.z1, 1, mix.x2, mix.y2, mix.z2, 1, t, mix.space, mix.hue_long)
  return cs.from_space(x, y, z, mix.space)
end

--- 係数 t で色1→色2を混ぜ、三角形ごとの HSV ばらつきを掛ける。
--- mix は mix_prepare の戻り値（nil なら sRGB の lerp）、var_space は apply_hsv_jitter の space。
--- どちらも省略できる（省略すると今までと同じ計算）。
function EffectUtils_Lowpoly.color_at(t, r1, g1, b1, r2, g2, b2, tri_idx, seed, hue_var, val_var, hue_phase, val_phase, mix, var_space)
  if mix then
    local r, g, b = EffectUtils_Lowpoly.mix_at(mix, t)
    return EffectUtils_Lowpoly.apply_hsv_jitter(
      r, g, b, tri_idx, seed, hue_var, 0, val_var, hue_phase, val_phase, var_space)
  end
  return EffectUtils_Lowpoly.apply_hsv_jitter(
    r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t,
    tri_idx, seed, hue_var, 0, val_var, hue_phase, val_phase, var_space)
end

function EffectUtils_Lowpoly.color_gradient(cx, cy, w, h, r1, g1, b1, r2, g2, b2, gradient_dir, tri_idx, seed, hue_var, val_var, hue_phase, val_phase)
  local t = EffectUtils_Lowpoly.gradient_t(cx, cy, w, h, gradient_dir)
  return EffectUtils_Lowpoly.color_at(
    t, r1, g1, b1, r2, g2, b2, tri_idx, seed, hue_var, val_var, hue_phase, val_phase)
end

-- 時間 -------------------------------------------------------------------

--- オブジェクトの先頭フレームから最終フレームまでの進度 0..1。
function EffectUtils_Lowpoly.object_progress(obj_ref)
  local frame = 0
  local total = 1
  if obj_ref then
    frame = tonumber(obj_ref.frame) or 0
    total = tonumber(obj_ref.totalframe) or 1
  end
  if total < 1 then total = 1 end
  local t = frame / math_max(total - 1, 1)
  return clamp(t, 0, 1), frame, total
end

--- ループ位相（ラジアン）。オブジェクト全体で loop_count 周ちょうど回る。
--- 整数周回なので端が必ず繋がる。旧版にあった「速度」は同じ軸の重複パラメータで、
--- 20 の整数倍以外ではループが繋がらなかったため廃止した。
function EffectUtils_Lowpoly.loop_phase(enabled, loop_count, obj_ref)
  if not EffectUtils_Lowpoly.as_bool(enabled, false) then
    return 0
  end
  local n = math_floor(tonumber(loop_count) or 1)
  if n < 1 then n = 1 end
  return EffectUtils_Lowpoly.object_progress(obj_ref) * n * math_pi * 2
end

-- 明転 ---------------------------------------------------------------------

--- 明転の起点キー 0..1。値が小さい三角形ほど先に明ける。
--- order: 0=ランダム / 1=グラデ方向 / 2=明るい順 / 3=暗い順 / 4=中心から
--- color_t を渡すと「グラデ方向」はその値を使う（ランダム配色では色1の三角形から明ける）。
--- グラデーション配色の color_t は gradient_t と同じ値なので、渡しても絵は変わらない。
function EffectUtils_Lowpoly.fade_key(order, tri_idx, seed, cx, cy, w, h, gradient_dir, r, g, b, color_t)
  order = math_floor(tonumber(order) or 0)
  if order == 1 then
    if color_t then
      return clamp(color_t, 0, 1)
    end
    return EffectUtils_Lowpoly.gradient_t(cx, cy, w, h, gradient_dir)
  elseif order == 2 or order == 3 then
    local v = math_max(r, math_max(g, b))   -- HSV の V に相当
    if order == 2 then v = 1 - v end        -- 明るい三角形を先に明ける
    return clamp(v, 0, 1)
  elseif order == 4 then
    local dx = (cx - w * 0.5) / math_max(w * 0.5, 1)
    local dy = (cy - h * 0.5) / math_max(h * 0.5, 1)
    return clamp(math_sqrt(dx * dx + dy * dy) / math_sqrt(2), 0, 1)
  end
  return hash21(tri_idx, 7, (seed or 0) + 500)
end

--- 三角形ごとの明転係数 0..1。progress は明転区間の中での進度。
--- spread 0 で全三角形が同時に明け、1 に近いほど key の順に開いていく。
--- span を最低 0.1 残すのは、spread=1 で切り替わりが瞬間になり段差として見えるため。
function EffectUtils_Lowpoly.fade_factor(progress, key, spread)
  local sp = clamp(spread or 0, 0, 1) * 0.9
  local start = clamp(key or 0, 0, 1) * sp
  local k = clamp((clamp(progress or 0, 0, 1) - start) / (1 - sp), 0, 1)
  return k * k * (3 - 2 * k)                -- smoothstep
end

--- 明転の色。色相・彩度を保ったまま明度だけ dark 倍から等倍へ持ち上げる。
--- RGB の一律スケールは HSV の V を動かすのと等価なので、純黒を経由しない。
--- dark = 1 のときは厳密に恒等（明転 OFF と出力が一致する）。
function EffectUtils_Lowpoly.fade_mix(r, g, b, k, dark)
  local v = dark + (1 - dark) * k
  return r * v, g * v, b * v
end

-- cbuffer 詰め ------------------------------------------------------------

--- 三角形レコード。payload_fn(i, tri, p0, p1, p2) は 4 つの float を返す。
--- @ローポリ背景 は r,g,b,a、@ローポリ化 は hue_off,sat_off,val_off,0 を入れる。
function EffectUtils_Lowpoly.build_tri_records(points, tris, payload_fn)
  local recs = {}
  for i = 1, #tris do
    local t = tris[i]
    local p0, p1, p2 = points[t[1]], points[t[2]], points[t[3]]
    local a, b, c, d = payload_fn(i, t, p0, p1, p2)
    recs[i] = {
      x0 = p0.x, y0 = p0.y,
      x1 = p1.x, y1 = p1.y,
      x2 = p2.x, y2 = p2.y,
      p0 = a or 0, p1 = b or 0, p2 = c or 0, p3 = d or 0,
    }
  end
  return recs
end

--- consts の末尾に 1 バッチ分を追加する。
--- 1 三角形 = 3 float4: x0,y0,x1,y1 / x2,y2,p0,p1 / p2,p3,0,0
--- 返り値は実際に詰めた三角形数（余りは 0 埋めしてレイアウトを固定する）。
function EffectUtils_Lowpoly.append_tri_batch(consts, recs, start_i, batch_n)
  local n = 0
  local k = #consts
  for i = 0, batch_n - 1 do
    local r = recs[start_i + i]
    if r then
      consts[k + 1] = r.x0
      consts[k + 2] = r.y0
      consts[k + 3] = r.x1
      consts[k + 4] = r.y1
      consts[k + 5] = r.x2
      consts[k + 6] = r.y2
      consts[k + 7] = r.p0
      consts[k + 8] = r.p1
      consts[k + 9] = r.p2
      consts[k + 10] = r.p3
      consts[k + 11] = 0
      consts[k + 12] = 0
      n = n + 1
    else
      for j = 1, 12 do
        consts[k + j] = 0
      end
    end
    k = k + 12
  end
  return n
end

-- 場所ごとのバッチ（ローポリ化 v3.30・強化デバッグ 7.5） ------------------------
--
-- 旧版の @通常 は三角形を Delaunay の出力順に 256 個ずつ区切って塗っていた。どのバッチも画面全体に散らばるので、
-- 1 画素はバッチごとに最大 256 個の三角形を調べ（FHD の既定で 7 バッチ、1 画素あたり約 1,700 回）、
-- これが 1 フレームの時間のほとんどだった（効果ぶん約 23ms。実機 2026-10-13）。
-- ここでは三角形の重心で画面を縦横に二分していき、近い三角形を同じバッチにまとめる（k-d 木の葉）。
-- 各バッチには頂点の外接矩形を付け、シェーダーは矩形の外の画素をループの前に抜ける。
-- 1 画素が調べる三角形は、自分の入るバッチ（と矩形が重なる隣のバッチ）の分だけになる。
-- ループの回数（バッチの三角形数）は画素によらず同じで、矩形の判定はループの外の 1 回だけ。

-- tris（get_mesh の戻り値。メッシュのメモ化と同じ表）ごとに区切り方を覚える。表が捨てられたら一緒に消える
local batch_cache = setmetatable({}, { __mode = "k" })

--- 三角形の番号（tris の添字）を場所ごとのバッチに分ける。
--- 戻り値: { { idx = {番号...}, x0, y0, x1, y1 }, ... }（x0..y1 は頂点の外接矩形）。各バッチは batch_n 個以下。
function EffectUtils_Lowpoly.spatial_batches(points, tris, batch_n)
  batch_n = batch_n or BATCH_SIZE
  local per = batch_cache[tris]
  if per and per[batch_n] then
    return per[batch_n]
  end

  local n = #tris
  local gx, gy = {}, {}
  local order = {}
  for i = 1, n do
    local t = tris[i]
    local a, b, c = points[t[1]], points[t[2]], points[t[3]]
    gx[i] = (a.x + b.x + c.x) / 3
    gy[i] = (a.y + b.y + c.y) / 3
    order[i] = i
  end

  local batches = {}
  local function emit(lo, hi)
    -- batch_n を超えたら（割り切れない端数で 1 個はみ出すとき）前から切る
    local s = lo
    while s <= hi do
      local e = math_min(hi, s + batch_n - 1)
      local idx = {}
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for k = s, e do
        local ti = order[k]
        idx[#idx + 1] = ti
        local t = tris[ti]
        for v = 1, 3 do
          local p = points[t[v]]
          if p.x < x0 then x0 = p.x end
          if p.y < y0 then y0 = p.y end
          if p.x > x1 then x1 = p.x end
          if p.y > y1 then y1 = p.y end
        end
      end
      batches[#batches + 1] = { idx = idx, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
      s = e + 1
    end
  end

  -- order[lo..hi] を c 個のバッチに分ける。重心の広がりが大きい向きで並べ、個数の比で切る
  local function split(lo, hi, c)
    local len = hi - lo + 1
    if c <= 1 or len <= batch_n then
      emit(lo, hi)
      return
    end
    local mnx, mny, mxx, mxy = math.huge, math.huge, -math.huge, -math.huge
    for k = lo, hi do
      local ti = order[k]
      local x, y = gx[ti], gy[ti]
      if x < mnx then mnx = x end
      if y < mny then mny = y end
      if x > mxx then mxx = x end
      if y > mxy then mxy = y end
    end
    local key = (mxx - mnx >= mxy - mny) and gx or gy
    local sub = {}
    for k = lo, hi do sub[#sub + 1] = order[k] end
    -- 同じ値は番号の順（並べ方を毎回同じにする）
    table.sort(sub, function(u, v)
      local ku, kv = key[u], key[v]
      if ku ~= kv then return ku < kv end
      return u < v
    end)
    for k = 1, len do order[lo + k - 1] = sub[k] end
    local cl = math_floor(c / 2)
    local cut = lo + math_floor(len * cl / c)
    split(lo, cut - 1, cl)
    split(cut, hi, c - cl)
  end

  if n > 0 then
    split(1, n, math_ceil(n / batch_n))
  end

  per = per or {}
  per[batch_n] = batches
  batch_cache[tris] = per
  return batches
end

--- consts の末尾に 1 バッチ分を追加する（append_tri_batch の、番号の列を渡す版）。
--- recs は build_tri_records の戻り値（tris の添字のまま）。レイアウトは append_tri_batch と同じで、
--- batch_n に満たない分は 0 で埋める。返り値は詰めた三角形数。
function EffectUtils_Lowpoly.append_tri_list(consts, recs, idx, batch_n)
  local k = #consts
  local m = #idx
  for i = 1, batch_n do
    local r = (i <= m) and recs[idx[i]] or nil
    if r then
      consts[k + 1] = r.x0
      consts[k + 2] = r.y0
      consts[k + 3] = r.x1
      consts[k + 4] = r.y1
      consts[k + 5] = r.x2
      consts[k + 6] = r.y2
      consts[k + 7] = r.p0
      consts[k + 8] = r.p1
      consts[k + 9] = r.p2
      consts[k + 10] = r.p3
      consts[k + 11] = 0
      consts[k + 12] = 0
    else
      for j = 1, 12 do
        consts[k + j] = 0
      end
    end
    k = k + 12
  end
  return math_min(m, batch_n)
end

-- グーロー（ローポリ化 v3.40・ローポリ背景 v3.40） -------------------------------------
--
-- 塗り方「グーロー」は、頂点ごとに色（ローポリ背景）か色のばらつき（ローポリ化）を持たせ、三角形の中で補間する。
-- 1 三角形に頂点 3 つ分の値（9 個）が要るので、1 三角形 = 4 float4（三角形ごとに 1 色の今までのレイアウトは 3 float4）。
-- シェーダーの tri[768] に 192 三角形が入る（GOURAUD_BATCH）。今までの関数（build_tri_records / append_tri_batch /
-- append_tri_list）は変えていない。
-- 検証器: AI/scripts/ローポリ/verify_gouraud.py

local GOURAUD_BATCH = 192

--- 頂点ごとの値を持つ三角形レコード。vals[j] は点 j の 3 値の表、last は 1 三角形の 10 個目の値（省略で 0）。
--- 同じ点を共有する三角形には同じ値が入るので、補間した色は辺をまたいでつながる（継ぎ目が出ない）。
function EffectUtils_Lowpoly.build_tri_records_vertex(points, tris, vals, last)
  local recs = {}
  last = last or 0
  for i = 1, #tris do
    local t = tris[i]
    local p0, p1, p2 = points[t[1]], points[t[2]], points[t[3]]
    local a, b, c = vals[t[1]], vals[t[2]], vals[t[3]]
    recs[i] = {
      x0 = p0.x, y0 = p0.y,
      x1 = p1.x, y1 = p1.y,
      x2 = p2.x, y2 = p2.y,
      g = { a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3], last },
    }
  end
  return recs
end

--- consts の末尾に 1 バッチ分を追加する（グーロー。1 三角形 = 4 float4）。
--- x0,y0,x1,y1 / x2,y2,g1,g2 / g3,g4,g5,g6 / g7,g8,g9,g10。batch_n に満たない分は 0 で埋める。返り値は詰めた三角形数。
function EffectUtils_Lowpoly.append_tri_list4(consts, recs, idx, batch_n)
  local k = #consts
  local m = #idx
  for i = 1, batch_n do
    local r = (i <= m) and recs[idx[i]] or nil
    if r then
      local g = r.g
      consts[k + 1] = r.x0
      consts[k + 2] = r.y0
      consts[k + 3] = r.x1
      consts[k + 4] = r.y1
      consts[k + 5] = r.x2
      consts[k + 6] = r.y2
      for j = 1, 10 do
        consts[k + 6 + j] = g[j]
      end
    else
      for j = 1, 16 do
        consts[k + j] = 0
      end
    end
    k = k + 16
  end
  return math_min(m, batch_n)
end

-- 多角形分割（ローポリ背景 v3.50 の @多角形分割） -----------------------------------------
--
-- 1. poly_points : 場所によって細かさが変わる点群（可変半径のポアソン円盤。外周は半径に沿って並べる）
-- 2. delaunay    : 既存の関数で三角形に分ける
-- 3. build_polygons : 隣り合う三角形を、凸のまま辺数の上限まで結合して多角形にする
--                     （描画は元の三角形のまま。多角形の中の対角線にはエッジを引かない）
-- 4. build_poly_records / append_tri_list_poly : 三角形ごとの色・エッジの印を cbuffer へ詰める
-- 既存の関数は変えていない。検証器: AI/scripts/ローポリ/verify_polymesh.py

local POLY_BATCH = 256        -- ps_lpbg_poly の tri[768]（1 三角形 = 3 float4）
local POLY_RHO = 0.9          -- 点どうしの最小距離 = POLY_RHO × その場所のセルサイズ
local POLY_AREA_K = 0.66      -- 点の数 ≒ POLY_AREA_K × 面積 / セルサイズ² + 外周（実測で合わせた。一様 40 で見積り 1022・実測 978）

local function smoothstep01(t)
  t = clamp(t, 0, 1)
  return t * t * (3 - 2 * t)
end

--- 密度の場 f(x, y)。0 = 粗い（セルサイズそのまま）、1 = 細かい（セルサイズ ÷ 細かさの比）。
--- mode: 0 一様 / 1 中心が細かい / 2 周囲が細かい / 3 左 / 4 右 / 5 上 / 6 下 が細かい / 7 ランダムな斑（size 画素ごと）
function EffectUtils_Lowpoly.density_field(mode, w, h, size, seed)
  mode = math_floor(tonumber(mode) or 0)
  seed = math_floor(tonumber(seed) or 0)
  w = math_max(w, 1)
  h = math_max(h, 1)
  if mode == 1 or mode == 2 then
    local cx, cy = w * 0.5, h * 0.5
    local rmax = math_max(math_sqrt(cx * cx + cy * cy), 1)
    return function(x, y)
      local dx, dy = x - cx, y - cy
      local f = smoothstep01(math_sqrt(dx * dx + dy * dy) / rmax)   -- 周囲ほど 1
      if mode == 1 then f = 1 - f end
      return f
    end
  elseif mode >= 3 and mode <= 6 then
    return function(x, y)
      local t
      if mode == 3 then
        t = 1 - x / w
      elseif mode == 4 then
        t = x / w
      elseif mode == 5 then
        t = 1 - y / h
      else
        t = y / h
      end
      return smoothstep01(t)
    end
  elseif mode == 7 then
    size = math_max(tonumber(size) or 600, 10)
    local sd = seed + 4100
    return function(x, y)
      local gx, gy = x / size, y / size
      local ix, iy = math_floor(gx), math_floor(gy)
      local fx, fy = smoothstep01(gx - ix), smoothstep01(gy - iy)
      local a = hash21(ix, iy, sd)
      local b = hash21(ix + 1, iy, sd)
      local c = hash21(ix, iy + 1, sd)
      local d = hash21(ix + 1, iy + 1, sd)
      local v = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
      return smoothstep01((v - 0.5) * 1.8 + 0.5)    -- 値ノイズは 0.5 付近に偏るので広げる
    end
  end
  return function() return 0 end
end

--- 密度つきの点群を作る。点は y → x の順に並べて返す（delaunay が速くなる並び）。
--- 戻り値: points（{x, y, ix, iy}）、実際に使った最も粗いセルサイズ（点数上限で引き上がることがある）
function EffectUtils_Lowpoly.poly_points(w, h, coarse, ratio, mode, size, seed)
  seed = math_floor(tonumber(seed) or 0)
  coarse = math_max(tonumber(coarse) or 100, 4)
  mode = math_floor(tonumber(mode) or 0)
  ratio = (mode == 0) and 1 or clamp(tonumber(ratio) or 1, 1, 8)
  local field = EffectUtils_Lowpoly.density_field(mode, w, h, size, seed)
  local function cell_at(x, y)
    return coarse * ratio ^ (-field(x, y))
  end

  -- 点数の見積り。上限を超えるなら粗い側のセルを引き上げる（密度の比は保つ）
  local nxs = 48
  local nys = math_max(1, math_floor(nxs * h / w + 0.5))
  local ax, ay = w / nxs, h / nys
  for _ = 1, 4 do
    local est = 0
    for j = 0, nys - 1 do
      for i = 0, nxs - 1 do
        local c = cell_at((i + 0.5) * ax, (j + 0.5) * ay)
        est = est + ax * ay / (c * c)
      end
    end
    est = est * POLY_AREA_K + 2 * (w + h) / (POLY_RHO * coarse)
    if est <= MAX_POINTS then break end
    coarse = coarse * math_sqrt(est / MAX_POINTS) * 1.02
  end

  local pts = {}
  local g = POLY_RHO * coarse / 2
  local cols = math_floor(w / g) + 1
  local stride = cols + 2
  local grid = {}
  local function add(x, y, r)
    pts[#pts + 1] = { x = x, y = y, r = r }
    local key = math_floor(y / g) * stride + math_floor(x / g)
    local lst = grid[key]
    if not lst then
      lst = {}
      grid[key] = lst
    end
    lst[#lst + 1] = #pts
  end

  -- 外周: 始点の角から終点の手前まで、その場所の間隔で並べる（終点の角は次の辺の始点）
  local function add_edge(x0, y0, x1, y1)
    local len = math_sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
    local ux, uy = (x1 - x0) / len, (y1 - y0) / len
    local list = {}
    local t = 0
    local step = 1
    while t < len - 1e-6 do
      local x, y = x0 + ux * t, y0 + uy * t
      step = POLY_RHO * cell_at(x, y)
      list[#list + 1] = { t = t, x = x, y = y, step = step }
      t = t + step
    end
    local n = #list
    if n >= 2 and len - list[n].t < 0.6 * list[n].step then
      list[n] = nil
    end
    for i = 1, #list do
      add(list[i].x, list[i].y, POLY_RHO * cell_at(list[i].x, list[i].y))
    end
  end
  add_edge(0, 0, w, 0)
  add_edge(w, 0, w, h)
  add_edge(w, h, 0, h)
  add_edge(0, h, 0, 0)

  -- 内側: 細かい側の半分の歩幅の揺らした格子を候補にし、乱数の順に、近すぎなければ採る
  local fine = coarse / ratio
  local s = math_max(fine * 0.5, math_sqrt(w * h / 120000), 1)
  local cands = {}
  local ncx, ncy = math_floor(w / s), math_floor(h / s)
  for iy = 0, ncy do
    for ix = 0, ncx do
      local x = (ix + hash21(ix, iy, seed + 31)) * s
      local y = (iy + hash21(ix, iy, seed + 32)) * s
      if x > 0 and x < w and y > 0 and y < h then
        local c = cell_at(x, y)
        local p = 4 * (s / c) * (s / c)            -- 1 セルあたり約 4 個の候補
        if p >= 1 or hash21(ix, iy, seed + 33) < p then
          cands[#cands + 1] = { x = x, y = y, c = c, k = hash21(ix, iy, seed + 34) }
        end
      end
    end
  end
  table.sort(cands, function(u, v) return u.k < v.k end)

  local cap = math_floor(MAX_POINTS * 1.3)
  for ci = 1, #cands do
    local cd = cands[ci]
    local r = POLY_RHO * cd.c
    local gx, gy = math_floor(cd.x / g), math_floor(cd.y / g)
    local ok = true
    for yy = gy - 2, gy + 2 do
      for xx = gx - 2, gx + 2 do
        local lst = grid[yy * stride + xx]
        if lst then
          for k = 1, #lst do
            local q = pts[lst[k]]
            local thr = 0.5 * (r + q.r)
            local dx, dy = cd.x - q.x, cd.y - q.y
            if dx * dx + dy * dy < thr * thr then
              ok = false
              break
            end
          end
        end
        if not ok then break end
      end
      if not ok then break end
    end
    if ok then
      add(cd.x, cd.y, r)
      if #pts >= cap then break end
    end
  end

  table.sort(pts, function(u, v)
    if u.y ~= v.y then return u.y < v.y end
    return u.x < v.x
  end)
  local out = {}
  for i = 1, #pts do
    out[i] = { x = pts[i].x, y = pts[i].y, ix = i, iy = 0, c = pts[i].r / POLY_RHO }   -- c = その場所のセルサイズ
  end
  return out, coarse
end

-- 密度つきのメッシュ（ローポリ化 v3.50 の @通常）。poly_points の点群に、ジッター格子（build_points）と同じ意味の揺らぎと
-- メッシュのアニメ（揺らぎのベクトルを位相で回す）を掛けて Delaunay にかける。外周の点は動かさない。
-- 揺らぎの大きさは 0.25 × その場所のセルサイズ × 揺らぎ%（近い点どうしは 0.9 × セルサイズ離れているので、重なって潰れない）。
local density_base_cache = {}
local density_cache = {}

--- 戻り値: points, tris（get_mesh と同じ形）、実際に使った最も粗いセルサイズ
function EffectUtils_Lowpoly.get_density_mesh(w, h, cell, ratio, mode, size, seed, jitter, phase)
  seed = math_floor(tonumber(seed) or 0)
  phase = phase or 0
  mode = math_floor(tonumber(mode) or 0)
  local bkey = string.format("%d,%d,%.3f,%.3f,%d,%.3f,%d", w, h, cell or 0, ratio or 1, mode, size or 0, seed)
  local key = string.format("%s,%.3f,%.6f", bkey, jitter or 0, phase)
  for i = 1, #density_cache do
    if density_cache[i].key == key then
      local e = density_cache[i]
      if i > 1 then
        table.remove(density_cache, i)
        table.insert(density_cache, 1, e)
      end
      return e.points, e.tris, e.used
    end
  end

  local base, used
  for i = 1, #density_base_cache do
    if density_base_cache[i].key == bkey then
      base, used = density_base_cache[i].points, density_base_cache[i].used
      break
    end
  end
  if not base then
    base, used = EffectUtils_Lowpoly.poly_points(w, h, cell, ratio, mode, size, seed)
    table.insert(density_base_cache, 1, { key = bkey, points = base, used = used })
    while #density_base_cache > 2 do
      table.remove(density_base_cache)
    end
  end

  local jit = clamp(tonumber(jitter) or 0, 0, 100) / 100
  local cos_p, sin_p = math_cos(phase), math_sin(phase)
  local points = {}
  for i = 1, #base do
    local p = base[i]
    local x, y = p.x, p.y
    if jit > 0 and x > 0 and x < w and y > 0 and y < h then
      local ox = (hash21(i, 1, seed + 61) - 0.5) * 2
      local oy = (hash21(i, 2, seed + 62) - 0.5) * 2
      local amp = 0.25 * p.c * jit
      x = x + (ox * cos_p - oy * sin_p) * amp
      y = y + (ox * sin_p + oy * cos_p) * amp
    end
    points[i] = { x = clamp(x, 0, w), y = clamp(y, 0, h), ix = p.ix, iy = p.iy }
  end
  local tris = EffectUtils_Lowpoly.delaunay(points)
  table.insert(density_cache, 1, { key = key, points = points, tris = tris, used = used })
  while #density_cache > MESH_CACHE_MAX do
    table.remove(density_cache)
  end
  return points, tris, used
end

--- 隣り合う三角形を結合して多角形にする。
--- 辺ごとに乱数で並べ、merge_rate（0..100）% の確率で、結合後も凸（微小な凹みは許す）で、
--- 角の数（ほぼ一直線の頂点は数えない）が max_sides 以下のときだけ結合する。
--- 戻り値: { points, tris（面積 0 を除いたもの）, tri_poly[i]（三角形 i の多角形の番号）, tri_mask[i]（エッジを引く辺の印。
--- 1 = 頂点 1→2、2 = 2→3、4 = 3→1。辺の向こうが別の多角形か外のときに立つ）, polys[番号] = { verts, tris }, live（生きている番号の列） }
function EffectUtils_Lowpoly.build_polygons(points, tris_in, merge_rate, max_sides, seed)
  seed = math_floor(tonumber(seed) or 0)
  merge_rate = clamp(tonumber(merge_rate) or 0, 0, 100)
  max_sides = math_floor(tonumber(max_sides) or 3)

  local tris = {}
  for i = 1, #tris_in do
    local t = tris_in[i]
    local a, b, c = points[t[1]], points[t[2]], points[t[3]]
    if math_abs(orient(a.x, a.y, b.x, b.y, c.x, c.y)) > 1e-6 then
      tris[#tris + 1] = t
    end
  end

  local K = 100000
  local dir = {}
  for i = 1, #tris do
    local t = tris[i]
    dir[t[1] * K + t[2]] = i
    dir[t[2] * K + t[3]] = i
    dir[t[3] * K + t[1]] = i
  end

  local polys, poly_of = {}, {}
  for i = 1, #tris do
    local t = tris[i]
    polys[i] = { verts = { t[1], t[2], t[3] }, tris = { i } }
    poly_of[i] = i
  end

  if merge_rate > 0 then
    local edges = {}
    for i = 1, #tris do
      local t = tris[i]
      for e = 1, 3 do
        local a, b = t[e], t[e % 3 + 1]
        if a < b and dir[b * K + a] then
          edges[#edges + 1] = { a, b, hash21(a, b, seed + 900) }
        end
      end
    end
    table.sort(edges, function(u, v)
      if u[3] ~= v[3] then return u[3] < v[3] end
      if u[1] ~= v[1] then return u[1] < v[1] end
      return u[2] < v[2]
    end)

    for ei = 1, #edges do
      local a, b = edges[ei][1], edges[ei][2]
      if hash21(a, b, seed + 901) * 100 < merge_rate then
        local ti, tj = dir[a * K + b], dir[b * K + a]
        local p, q = poly_of[ti], poly_of[tj]
        if p ~= q then
          local pv, qv = polys[p].verts, polys[q].verts
          local pn, qn = #pv, #qv
          -- P は a→b、Q は b→a の向きでこの辺を持つ。P を b から a まで、続けて Q の内側の頂点を並べると結合後の輪になる
          local ia, qb
          for i = 1, pn do
            if pv[i] == a and pv[i % pn + 1] == b then ia = i break end
          end
          for i = 1, qn do
            if qv[i] == b and qv[i % qn + 1] == a then qb = i break end
          end
          if ia and qb then
            local ib = ia % pn + 1
            local qa = qb % qn + 1
            local merged = {}
            for k = 0, pn - 1 do
              merged[#merged + 1] = pv[(ib - 1 + k) % pn + 1]
            end
            for k = 1, qn - 2 do
              merged[#merged + 1] = qv[(qa - 1 + k) % qn + 1]
            end
            local m = #merged
            local good = m <= 16
            if good then
              local seen = {}
              for i = 1, m do
                if seen[merged[i]] then good = false break end
                seen[merged[i]] = true
              end
            end
            local corners = 0
            if good then
              for i = 1, m do
                local v0 = points[merged[(i - 2) % m + 1]]
                local v1 = points[merged[i]]
                local v2 = points[merged[i % m + 1]]
                local ex, ey = v1.x - v0.x, v1.y - v0.y
                local fx, fy = v2.x - v1.x, v2.y - v1.y
                local l = math_sqrt(ex * ex + ey * ey) * math_sqrt(fx * fx + fy * fy)
                if l < 1e-9 then good = false break end
                local sn = (ex * fy - ey * fx) / l
                if sn < -0.01 then good = false break end
                if sn > 0.01 then corners = corners + 1 end
              end
            end
            if good and corners <= max_sides then
              local keep, drop = math_min(p, q), math_max(p, q)
              local kt, dt = polys[keep].tris, polys[drop].tris
              for k = 1, #dt do
                kt[#kt + 1] = dt[k]
                poly_of[dt[k]] = keep
              end
              polys[keep].verts = merged
              polys[drop] = nil
            end
          end
        end
      end
    end
  end

  local tri_mask = {}
  for i = 1, #tris do
    local t = tris[i]
    local pid = poly_of[i]
    local mask = 0
    for e = 1, 3 do
      local u, v = t[e], t[e % 3 + 1]
      local nb = dir[v * K + u]
      if (not nb) or poly_of[nb] ~= pid then
        mask = mask + 2 ^ (e - 1)
      end
    end
    tri_mask[i] = mask
  end

  local live = {}
  for i = 1, #tris do
    if polys[i] then live[#live + 1] = i end
  end
  return { points = points, tris = tris, tri_poly = poly_of, tri_mask = tri_mask, polys = polys, live = live }
end

local poly_cache = {}

--- 点群 → 三角形分割 → 多角形の結合を、パラメータをキーにメモ化して返す（色・塗りは含まない）。
function EffectUtils_Lowpoly.get_poly_mesh(w, h, cell, ratio, mode, size, seed, merge_rate, max_sides)
  local key = string.format("%d,%d,%.3f,%.3f,%d,%.3f,%d,%.3f,%d",
    w, h, cell or 0, ratio or 1, math_floor(mode or 0), size or 0, math_floor(seed or 0), merge_rate or 0, math_floor(max_sides or 3))
  for i = 1, #poly_cache do
    if poly_cache[i].key == key then
      local e = poly_cache[i]
      if i > 1 then
        table.remove(poly_cache, i)
        table.insert(poly_cache, 1, e)
      end
      return e.mesh
    end
  end
  local points = EffectUtils_Lowpoly.poly_points(w, h, cell, ratio, mode, size, seed)
  local tris = EffectUtils_Lowpoly.delaunay(points)
  local mesh = EffectUtils_Lowpoly.build_polygons(points, tris, merge_rate, max_sides, seed)
  table.insert(poly_cache, 1, { key = key, mesh = mesh })
  while #poly_cache > MESH_CACHE_MAX do
    table.remove(poly_cache)
  end
  return mesh
end

--- 多角形の頂点の平均（グラデーションの位置に使う）。
function EffectUtils_Lowpoly.poly_center(points, verts)
  local sx, sy = 0, 0
  for i = 1, #verts do
    sx = sx + points[verts[i]].x
    sy = sy + points[verts[i]].y
  end
  local n = math_max(#verts, 1)
  return sx / n, sy / n
end

--- 三角形ごとのレコード。pay[多角形の番号] = { r, g, b, a }（a が 0 なら塗らない）。
--- outline が true なら、塗らない面にもエッジだけを描く印（eo）を立てる。
function EffectUtils_Lowpoly.build_poly_records(mesh, pay, outline)
  local recs = {}
  local points = mesh.points
  for i = 1, #mesh.tris do
    local t = mesh.tris[i]
    local p0, p1, p2 = points[t[1]], points[t[2]], points[t[3]]
    local pl = pay[mesh.tri_poly[i]]
    recs[i] = {
      x0 = p0.x, y0 = p0.y,
      x1 = p1.x, y1 = p1.y,
      x2 = p2.x, y2 = p2.y,
      p0 = pl[1], p1 = pl[2], p2 = pl[3], p3 = pl[4],
      m = mesh.tri_mask[i],
      eo = (pl[4] <= 0 and outline) and 1 or 0,
    }
  end
  return recs
end

--- consts の末尾に 1 バッチ分を追加する（1 三角形 = 3 float4: x0,y0,x1,y1 / x2,y2,r,g / b,a,辺の印,枠だけの印）。
--- batch_n に満たない分は 0 で埋める。返り値は詰めた三角形数。
function EffectUtils_Lowpoly.append_tri_list_poly(consts, recs, idx, batch_n)
  local k = #consts
  local m = #idx
  for i = 1, batch_n do
    local r = (i <= m) and recs[idx[i]] or nil
    if r then
      consts[k + 1] = r.x0
      consts[k + 2] = r.y0
      consts[k + 3] = r.x1
      consts[k + 4] = r.y1
      consts[k + 5] = r.x2
      consts[k + 6] = r.y2
      consts[k + 7] = r.p0
      consts[k + 8] = r.p1
      consts[k + 9] = r.p2
      consts[k + 10] = r.p3
      consts[k + 11] = r.m
      consts[k + 12] = r.eo
    else
      for j = 1, 12 do
        consts[k + j] = 0
      end
    end
    k = k + 12
  end
  return math_min(m, batch_n)
end

EffectUtils_Lowpoly.POLY_BATCH = POLY_BATCH
EffectUtils_Lowpoly.GOURAUD_BATCH = GOURAUD_BATCH
EffectUtils_Lowpoly.MAX_POINTS = MAX_POINTS
EffectUtils_Lowpoly.BATCH_SIZE = BATCH_SIZE
EffectUtils_Lowpoly.OKLCH_C_REF = OKLCH_C_REF
EffectUtils_Lowpoly.SRC_CACHE = "cache:lowpoly/src"

return EffectUtils_Lowpoly
