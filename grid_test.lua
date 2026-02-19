-- Yksinkertainen grid-testi
-- grid_test.lua

local g = nil

function init()
  print("=== GRID TEST ===")
  
  -- Yhdistä grid
  g = grid.connect(1)
  print("Grid object: " .. tostring(g))
  
  if g then
    print("Grid found!")
    print("Cols: " .. (g.cols or 0))
    print("Rows: " .. (g.rows or 0))
    
    -- Jos midigrid ja dimensiot 0, pakota 16x8
    if (g.cols == 0 or g.rows == 0) then
      print("Forcing midigrid dimensions: 16x8")
      g.cols = 16
      g.rows = 8
    end
    
    -- Yksinkertainen testi-patterni
    draw_test_pattern()
    
    -- Aloita virkistys-metro
    local redraw_metro = metro.init()
    redraw_metro.time = 1.0
    redraw_metro.event = function()
      draw_test_pattern()
    end
    redraw_metro:start()
    print("Grid test pattern started!")
  else
    print("NO GRID FOUND!")
  end
end

function draw_test_pattern()
  if not g then return end
  
  pcall(function()
    g:all(0)  -- Tyhjennä
    
    -- Vilkkuva neliö vasemmassa yläkulmassa
    local blink = (math.floor(util.time()) % 2) == 0
    if blink then
      g:led(1, 1, 15)  -- Kirkas valo
      g:led(2, 1, 15)
      g:led(1, 2, 15)
      g:led(2, 2, 15)
    end
    
    -- Kiinteä valo oikeassa yläkulmassa
    local cols = g.cols or 16
    g:led(cols, 1, 8)  -- Keskikirkas
    g:led(cols-1, 1, 4)  -- Himmeä
    
    -- Vaakaviiva keskelle
    local rows = g.rows or 8
    local center_y = math.ceil(rows / 2)
    for x = 1, cols do
      g:led(x, center_y, 2)  -- Hyvin himmeä
    end
    
    g:refresh()
    print("Grid pattern drawn: " .. cols .. "x" .. rows)
  end)
end

function key(n, z)
  if n == 2 and z == 1 then
    print("K2: Drawing extra pattern")
    if g then
      pcall(function()
        g:all(8)  -- Kaikki keskikirkkaat
        g:refresh()
      end)
    end
  elseif n == 3 and z == 1 then
    print("K3: Clearing grid")
    if g then
      pcall(function()
        g:all(0)  -- Tyhjennä
        g:refresh()
      end)
    end
  end
end