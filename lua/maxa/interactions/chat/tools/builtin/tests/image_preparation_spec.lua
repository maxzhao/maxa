-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/image_preparation_spec.lua
-- Focused tests for strict reusable mcpx image preparation.
-- Run: nvim --headless -l lua/maxa/interactions/chat/tools/builtin/tests/image_preparation_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name)
    print("  Error: " .. tostring(err))
  end
end
local function assert_equal(expected, actual, message)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", message or "assertion failed", tostring(expected), tostring(actual)))
  end
end
local function assert_truthy(value, message)
  if not value then
    error(message or "expected truthy value")
  end
end
local function assert_match(pattern, value, message)
  if type(value) ~= "string" or not value:match(pattern) then
    error(string.format("%s: pattern %q not found in %q", message or "assertion failed", pattern, tostring(value)))
  end
end

local original_system = vim.fn.system
local function identify(path)
  local output = original_system({ "magick", "identify", "-format", "%w %h", path })
  assert_equal(0, vim.v.shell_error, "identify fixture")
  local width, height = output:match("(%d+)%s+(%d+)")
  return tonumber(width), tonumber(height)
end

local encoded_path, encoded_width, encoded_height
package.loaded["maxa.utils.images"] = {
  encode_image = function(options)
    encoded_path = options.path
    encoded_width, encoded_height = identify(options.path)
    return { path = options.path, id = options.id, base64 = "iVBORw0KGgo=" }
  end,
}
package.loaded["maxa.interactions.chat.tools.builtin.runtime.image_preparation"] = nil
local preparation = require("maxa.interactions.chat.tools.builtin.runtime.image_preparation")

local fixture_dir = vim.fn.tempname()
vim.fn.mkdir(fixture_dir, "p")
local fixtures = {
  png = fixture_dir .. "/landscape.png",
  jpeg = fixture_dir .. "/photo.unknown",
  bmp = fixture_dir .. "/source.bin",
  gif = fixture_dir .. "/single.data",
  animated = fixture_dir .. "/animated.gif",
  corrupt = fixture_dir .. "/corrupt",
  svg = fixture_dir .. "/vector.data",
  pdf = fixture_dir .. "/document.data",
  png_svg_metadata = fixture_dir .. "/svg-metadata.png",
  jpeg_svg_metadata = fixture_dir .. "/svg-metadata.unknown",
  svg_prolog = fixture_dir .. "/vector-prolog.png",
  svg_empty = fixture_dir .. "/vector-empty.png",
}
original_system({ "magick", "-size", "400x200", "xc:#336699", fixtures.png })
assert_equal(0, vim.v.shell_error, "create PNG")
original_system({ "magick", "-size", "120x60", "xc:#446688", "jpeg:" .. fixtures.jpeg })
assert_equal(0, vim.v.shell_error, "create JPEG")
original_system({ "magick", "-size", "80x40", "xc:#884466", "bmp:" .. fixtures.bmp })
assert_equal(0, vim.v.shell_error, "create BMP")
original_system({ "magick", "-size", "64x32", "xc:#886644", "gif:" .. fixtures.gif })
assert_equal(0, vim.v.shell_error, "create GIF")
original_system({ "magick", "-size", "20x20", "xc:red", "-size", "20x20", "xc:blue", fixtures.animated })
assert_equal(0, vim.v.shell_error, "create animated GIF")
vim.fn.writefile({ "not an image" }, fixtures.corrupt)
vim.fn.writefile({ '<svg xmlns="http://www.w3.org/2000/svg"/>' }, fixtures.svg)
vim.fn.writefile({ "%PDF-1.4", "%%EOF" }, fixtures.pdf, "b")
for _, case in ipairs({
  { "png", fixtures.png_svg_metadata },
  { "jpeg", fixtures.jpeg_svg_metadata },
}) do
  original_system({
    "magick",
    "-size",
    "40x20",
    "xc:#336699",
    "-set",
    "comment",
    '<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>',
    case[1] .. ":" .. case[2],
  })
  assert_equal(0, vim.v.shell_error, "create raster with SVG metadata")
  local fd = assert(vim.uv.fs_open(case[2], "r", 438))
  local prefix = assert(vim.uv.fs_read(fd, 4096, 0))
  vim.uv.fs_close(fd)
  assert_match("<svg[%s>]", prefix, "fixture must reproduce SVG text in first 4096 bytes")
end
vim.fn.writefile({
  '\239\187\191  <?xml version="1.0"?>',
  "<!-- vector document -->",
  '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">',
  '<svg xmlns="http://www.w3.org/2000/svg"/>',
}, fixtures.svg_prolog)
vim.fn.writefile({ "<svg/>" }, fixtures.svg_empty)

local function prepare(params)
  encoded_path, encoded_width, encoded_height = nil, nil, nil
  return preparation.prepare(params)
end

local invalid_cases = {
  { {}, "path is required" },
  { { path = "   " }, "path is required" },
  { { path = vim.NIL }, "path is required" },
  { { path = fixtures.png, extra = true }, "unknown image parameter" },
  { { path = fixtures.png, detail = "" }, "detail must be one" },
  { { path = fixtures.png, target_long_edge = 0 }, "target_long_edge" },
  { { path = fixtures.png, target_long_edge = 1.5 }, "target_long_edge" },
  { { path = fixtures.png, target_long_edge = 0 / 0 }, "target_long_edge" },
  { { path = fixtures.png, target_long_edge = math.huge }, "target_long_edge" },
  { { path = fixtures.png, resize_mode = "" }, "resize_mode must be one" },
  { { path = fixtures.png, region = { x = 0, y = 0, w = 50 } }, "region.h must be a finite number" },
  { { path = fixtures.png, region = { x = 0, y = 0, w = 50, h = 50, z = 1 } }, "unknown region parameter" },
  { { path = fixtures.png, region = { x = 0 / 0, y = 0, w = 50, h = 50 } }, "region.x must be a finite number" },
  { { path = fixtures.png, region = { x = 0, y = 0, w = 0, h = 50 } }, "region.w and region.h must be > 0" },
}
for index, case in ipairs(invalid_cases) do
  test("strict invalid image arguments #" .. index, function()
    local result, err = prepare(case[1])
    assert_equal(nil, result)
    assert_match(case[2], err)
    assert_equal(nil, encoded_path, "invalid input must not encode")
    assert_truthy(#err <= 803, "error must stay bounded")
  end)
end

test("direct decoded JPEG preserves original bytes and factual metadata", function()
  local before = vim.fn.sha256(table.concat(vim.fn.readfile(fixtures.jpeg, "b"), "\n"))
  local result, err = prepare({ path = fixtures.jpeg, detail = "high" })
  assert_equal(nil, err)
  assert_equal(fixtures.jpeg, encoded_path)
  assert_equal("JPEG", result.metadata.source_format)
  assert_equal("JPEG", result.metadata.final_format)
  assert_equal("image/jpeg", result.metadata.mimetype)
  assert_equal(120, result.metadata.original_width)
  assert_equal(60, result.metadata.height)
  assert_equal("high", result.metadata.detail)
  assert_equal(false, result.metadata.normalized)
  assert_equal(before, vim.fn.sha256(table.concat(vim.fn.readfile(fixtures.jpeg, "b"), "\n")), "original changed")
end)

test("raster SVG metadata is not mistaken for a vector document", function()
  for _, case in ipairs({
    { fixtures.png_svg_metadata, "PNG", "image/png" },
    { fixtures.jpeg_svg_metadata, "JPEG", "image/jpeg" },
  }) do
    local result, err = prepare({ path = case[1] })
    assert_equal(nil, err)
    assert_equal(case[1], encoded_path, "metadata must not cause re-encoding")
    assert_equal(case[2], result.metadata.source_format)
    assert_equal(case[3], result.payload.mimetype)
    assert_equal(40, result.metadata.width)
    assert_equal(20, result.metadata.height)
  end
end)

test("single-frame GIF remains direct", function()
  local result, err = prepare({ path = fixtures.gif })
  assert_equal(nil, err)
  assert_equal(fixtures.gif, encoded_path)
  assert_equal("GIF", result.metadata.final_format)
  assert_equal("image/gif", result.payload.mimetype)
end)

test("unsupported raster normalizes to verified 8-bit sRGB PNG and cleans temp", function()
  local result, err = prepare({ path = fixtures.bmp })
  assert_equal(nil, err)
  assert_equal("BMP", result.metadata.source_format)
  assert_equal("PNG", result.metadata.final_format)
  assert_equal("image/png", result.payload.mimetype)
  assert_equal(true, result.metadata.normalized)
  assert_truthy(encoded_path:match("%.png$"))
  assert_equal(0, vim.fn.filereadable(encoded_path), "temporary output was not cleaned")
end)

test("percentage crop is floored and applied before resize eligibility", function()
  local result, err = prepare({
    path = fixtures.png,
    region = { x = 10.1, y = 0, w = 25.9, h = 100 },
    target_long_edge = 400,
    resize_mode = "upscale_only",
  })
  assert_equal(nil, err)
  assert_equal(true, result.metadata.cropped)
  assert_equal(true, result.metadata.resized)
  assert_equal("upscale", result.metadata.resize_direction)
  assert_equal(206, result.metadata.width)
  assert_equal(400, result.metadata.height)
  assert_equal(206, encoded_width)
  assert_equal(400, encoded_height)
  assert_equal(0, vim.fn.filereadable(encoded_path), "temporary output was not cleaned")
end)

test("null image options use the same defaults as path-only input", function()
  local path_only, path_err = prepare({ path = fixtures.png })
  assert_equal(nil, path_err)
  local result, err = prepare({
    path = fixtures.png,
    detail = vim.NIL,
    region = vim.NIL,
    target_long_edge = vim.NIL,
    resize_mode = vim.NIL,
  })
  assert_equal(nil, err)
  assert_truthy(vim.deep_equal(path_only.metadata, result.metadata), "null options changed processing defaults")
  assert_equal(fixtures.png, encoded_path)
  assert_equal("original", result.metadata.detail)
  assert_equal("downscale_only", result.metadata.resize_mode)
  assert_equal(false, result.metadata.cropped)
  assert_equal(false, result.metadata.resized)
end)

test("resize mode without a target has no pixel effect", function()
  local result, err = prepare({ path = fixtures.png, resize_mode = "upscale_only" })
  assert_equal(nil, err)
  assert_equal(false, result.metadata.resized)
  assert_equal(400, result.metadata.width)
  assert_equal(fixtures.png, encoded_path)
end)

test("animated and invalid non-raster content are rejected", function()
  for _, case in ipairs({
    { fixtures.animated, "multi%-frame" },
    { fixtures.corrupt, "Failed to decode image content" },
    { fixtures.svg, "SVG input is not supported" },
    { fixtures.svg_prolog, "SVG input is not supported" },
    { fixtures.svg_empty, "SVG input is not supported" },
    { fixtures.pdf, "PDF input is not supported" },
  }) do
    local result, err = prepare({ path = case[1] })
    assert_equal(nil, result)
    assert_match(case[2], err)
  end
end)

vim.fn.system = original_system
vim.fn.delete(fixture_dir, "rf")
print(string.format("image_preparation tests: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
