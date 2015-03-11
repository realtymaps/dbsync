_ = require 'lodash'

_createLogger = (level) ->
  levels = [
    'debug'
    'info'
    'warn'
    'error'
  ]
  if typeof level != 'string'
    throw new Error("invalid logging option")
  if level == 'silent'
    index = levels.length
  else
    if !level in levels
      throw new Error("invalid logging option: '#{level}'")
    index = levels.indexOf(level)
  logger = {}
  noop = () -> return undefined
  for levelName,i in levels
    logger[levelName] = if i<index then noop else console[levelName]||console.log
  logger.log = console.log
  return logger

module.exports =
  getLogger: (logger) ->
    if !logger
      return _createLogger('silent')
    else if typeof logger == 'object'
      if _.isFunction(logger.debug) && _.isFunction(logger.info) && _.isFunction(logger.warn) && _.isFunction(logger.error) && _.isFunction(logger.log)
        return logger
    else if typeof logger == 'string'
      return _createLogger(logger)
    else
      throw new Error("invalid logging option")
