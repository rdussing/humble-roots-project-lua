local sms = require("sms")
local utils = require("utils")
local shell = require("shell")

local log = _ENV.log
local alerts = {}
local trace = {}

local function _trace(line)
  table.insert(trace, line)
end

local function _traceReset()
  trace = {}
  _trace("{")
end

local function _traceDump(prefix)
  _trace("}")
  local str = table.concat(trace, " ")
  log.trace(string.format("%s %s", prefix, str))
end

local function getAlertObj()
  local now = os.time()
  local obj = {
    ["created"] = now,
    ["modified"] = now
  }
  return obj
end

local function decode(data)
  local andTable = utils.splitString(data, '&')
  local t = {}
  for i = 1, #andTable, 1 do
    local kvPair = andTable[i]
    local values = utils.splitString(kvPair, '=')
    if #values == 2 then
      t[values[1]] = values[2]
    end
  end
  return t
end

local function isTimeWithinRange(timeNow, fromTime, toTime)
  if fromTime > toTime then
    if timeNow >= fromTime or timeNow <= toTime then
      _trace("time(>)")
      return true
    end
  elseif fromTime < toTime then
    if timeNow >= fromTime and timeNow <= toTime then
      _trace("time(<)")
      return true
    end
  elseif fromTime == toTime then
    if timeNow == fromTime then
      _trace("time(==)")
      return true
    end
  end
  return false
end

local dayMap = {}
dayMap[1] = "sun"
dayMap[2] = "mon"
dayMap[3] = "tue"
dayMap[4] = "wed"
dayMap[5] = "thu"
dayMap[6] = "fri"
dayMap[7] = "sat"

local function isTodayWithinDays(date, days)  
  local today = dayMap[date.wday]
  for i in ipairs(days) do
    local day = days[i]
    if day == today then
      _trace(string.format("%s", day))
      return true
    end
  end
  _trace(string.format("!%s", today))
  return false
end

local function evalCondition(value, condition)
  local date = os.date("*t", os.time())
  if condition.days ~= nil then
    if not isTodayWithinDays(date, condition.days) then
      return false
    end
  end
  if condition.from ~= nil and condition.to ~= nil then
    _trace(string.format("from %s to %s", condition.from, condition.to))
    
    if condition.from == "00:00" and condition.to == "23:59" then
      return true
    end
    
    local from = utils.splitString(condition.from, ':')
    local to = utils.splitString(condition.to, ':')
    local fromTime = os.date("*t", os.time())
    local toTime = os.date("*t", os.time())
    fromTime.hour = tonumber(from[1])
    fromTime.min = tonumber(from[2])
    fromTime.sec = 0
    toTime.hour = tonumber(to[1])
    toTime.min = tonumber(to[2])
    toTime.sec = 0
    return isTimeWithinRange(os.time(date), os.time(fromTime), os.time(toTime))
  elseif condition.op ~= nil and condition.setpoint ~= nil then
    local setPoint = tonumber(condition.setpoint)
    if condition.op == "==" and value == setPoint then
      _trace(string.format("%s %s %s", value, condition.op, condition.setpoint))
      return true
    elseif condition.op == ">=" and value >= setPoint then
      _trace(string.format("%s %s %s", value, condition.op, condition.setpoint))
      return true
    elseif condition.op == "<=" and value <= setPoint then
      _trace(string.format("%s %s %s", value, condition.op, condition.setpoint))
      return true
    elseif condition.op == ">" and value > setPoint then
      _trace(string.format("%s %s %s", value, condition.op, condition.setpoint))
      return true
    elseif condition.op == "<" and value < setPoint then
      _trace(string.format("%s %s %s", value, condition.op, condition.setpoint))
      return true
    elseif condition.op == "!=" and value ~= setPoint then
      _trace(string.format("%s %s %s", value, condition.op, condition.setpoint))
      return true
    end
  elseif condition.op == nil and condition.cmd ~= nil then
    return true
  elseif condition.op == nil and condition.cmd == nil and condition.title ~= nil then
    return true
  else
    return false
  end
end

local function resolve(cmdTable, cfg)
  local resolved = {}
  for key, value in pairs(cmdTable) do
    local cfgItem = cfg[key]
    if cfgItem ~= nil then
      resolved[key] = cfgItem[value]
    else
      resolved[key] = value
    end
  end
  return resolved
end

local function encode(cmdTable)
  local node = {}
  local other = {}
  for key, value in pairs(cmdTable) do
    if key == "node" then
      table.insert(node, string.format("%s=%s", key, value))
    else
      table.insert(other, string.format("%s=%s", key, value))
    end
  end
  table.sort(node)
  table.sort(other)
  return string.format("%s&%s", table.concat(node, "&"), table.concat(other, "&"))
end

local function encodeShellToDevice(opts, cfg)
  if opts.n ~= nil and opts.s ~= nil and (opts.r ~= nil or opts.v ~= nil) then
    opts.node = opts.n
    opts.n = nil
    opts.cmd = "act"
    local resolvedCmd = resolve(opts, cfg)
    local encodedCmd = encode(resolvedCmd)
    return encodedCmd
  else
    return nil
  end
end

local oppositeOp = {}
oppositeOp[">"] = "<"
oppositeOp["<"] = ">"
oppositeOp[">="] = "<="
oppositeOp["<="] = ">="
oppositeOp["=="] = "!="
oppositeOp["!="] = "=="

local function composeAlert(cfg, value, rule, clear)
  local mark = ""
  local sign = ""
  if clear then
    mark = cfg.alerts.clear
    sign = oppositeOp[rule.alert.op]
  else
    mark = cfg.alerts.raise
    sign = rule.alert.op
  end
  if rule.alert.setpoint ~= nil then
    return string.format(
      "[%s] %s %s %s %s %s @ %s",
      rule.node,
      rule.alert.title,
      mark,
      value,
      sign,
      rule.alert.setpoint,
      os.date("%c", os.time())
    )
  end
  
  return string.format(
    "[%s] %s %s @ %s",
    rule.node,
    rule.alert.title,
    mark,
    os.date("%c", os.time())
  )

end

local function getRuleHash(rule)
  return string.format("%s%s", rule.node, rule)
end

local function sendAlert(cfg, value, rule)
  local hash = getRuleHash(rule)
  if alerts[hash] == nil then
    alerts[hash] = getAlertObj()
    local alertMsg = composeAlert(cfg, value, rule, false)
    sms.send(cfg, alertMsg)
    log.warn(alertMsg)
  else
    local obj = alerts[hash]
    obj.modified = os.time()
  end
end

local function clearAlert(cfg, value, rule)
  local hash = getRuleHash(rule)
  if alerts[hash] ~= nil then
    alerts[hash] = nil
    local alertMsg = composeAlert(cfg, value, rule, true)
    sms.send(cfg, alertMsg)
    log.warn(alertMsg)
  end
end

local lastCommandSent = ""
local function commandSink(cmdFinal, gateway, cfg)
  if cmdFinal == lastCommandSent then
    log.debug(string.format("Ignoring duplicate cmd: %s", cmdFinal))
    return nil
  end
  
  lastCommandSent = cmdFinal
  
  if cmdFinal ~= nil then
    if cfg.serial.enabled then
      gateway.send(cmdFinal, nil)
    else
      log.trace(string.format("Would send: %s", cmdFinal))
    end
    return cmdFinal
  end
  return nil
end

local function sendCommand(cmd, gateway, cfg)
  if cmd == nil then
    log.error(string.format("Empty command!"))
    return nil
  end
  
  local start, _ = string.find(cmd, "-n")
  if start == 1 then
    local opts = shell.parse(cmd)
    local cmdFinal = encodeShellToDevice(opts, cfg)
    if cmdFinal == nil then
      log.fatal(string.format("Invalid cmd: %s", cmd))
      return nil
    end
    log.info(string.format("Cmd: %s", cmd))
    return commandSink(cmdFinal, gateway, cfg)
  else
    log.fatal(string.format("Deprecated syntax: %s", cmd))
    return nil
  end
end

local function eval(rule, msg, gateway, cfg)
  _traceReset()
  
  msg.actualValue = tonumber(msg[rule.value])
  
  if msg.actualValue == nil then
    _traceDump("nil msg.actualValue")
    return false
  end
  
  if rule.calib ~= nil then
    msg.actualValue = msg.actualValue + rule.calib
    msg[rule.value] = tostring(msg.actualValue)
    _trace(string.format("%s.%s == %s (calib. offset: %s)", rule.node or "_", rule.value, msg.actualValue, rule.calib))
  else
    _trace(string.format("%s.%s == %s", rule.node or "_", rule.value, msg.actualValue))
  end
  
  if rule.enabled == nil or not rule.enabled then
    log.trace("rule disabled")
    return false
  end

  if rule.time ~= nil and not evalCondition(msg.actualValue, rule.time, msg) then
    _traceDump("not time")
    return false
  end
  
  if rule.alert ~= nil and rule.node ~= nil then
    if evalCondition(msg.actualValue, rule.alert, msg) then
      _traceDump("alert raised")
      sendAlert(cfg, msg.actualValue, rule)
    else
      _traceDump("alert cleared")
      clearAlert(cfg, msg.actualValue, rule)
    end
  end
  
  if rule.on ~= nil and rule.on.cmd ~= nil and evalCondition(msg.actualValue, rule.on, msg) then
    _traceDump("on")
    sendCommand(rule.on.cmd, gateway, cfg)
    return true
  end
  
  if rule.off ~= nil and rule.off.cmd ~= nil and evalCondition(msg.actualValue, rule.off, msg) then
    _traceDump("off")
    sendCommand(rule.off.cmd, gateway, cfg)
    return true
  end
  
  if rule.cmd ~= nil then
    _traceDump("default")
    sendCommand(rule.cmd, gateway, cfg)
    return true
  end
  
  _traceDump("no match")
  
  return false
end

local function resetAlerts()
  alerts = {}
end

local export = {}
export.eval = eval
export.decode = decode
export.encode = encode
export.resolve = resolve
export.sendCommand = sendCommand
export.resetAlerts = resetAlerts
return export
