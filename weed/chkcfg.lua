local log = require("log")
_ENV.log = log
local config = require("config")
local cfg = config.getConfig("./config/config.json")
print("Valid JSON.")