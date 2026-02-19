-- Grid controller: wraps GridVisualizer, handles connect and setup/stop.
-- Exposes .g, .grid_cols, .grid_rows after setup() for main (e.g. redraw checks).

local GridVisualizer = include("lib/grid_visualizer")

local GridController = {}
GridController.__index = GridController

function GridController.new(opts)
  local self = setmetatable({}, GridController)
  self.visualizer = GridVisualizer.new(opts)
  self.g = nil
  self.grid_cols = 0
  self.grid_rows = 0
  return self
end

function GridController:setup()
  self.visualizer:setup()
  self.g = self.visualizer.g
  self.grid_cols = self.visualizer.grid_cols or 0
  self.grid_rows = self.visualizer.grid_rows or 0
end

function GridController:stop()
  if self.visualizer then
    self.visualizer:stop()
  end
  self.g = nil
  self.grid_cols = 0
  self.grid_rows = 0
end

function GridController:add_params()
  if self.visualizer then
    self.visualizer:add_params()
  end
end

function GridController:is_ready()
  return self.visualizer and self.visualizer:is_ready()
end

return GridController
