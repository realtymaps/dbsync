# this performs an operation very similar to what coffee-script does automatically to implement fat-arrow, but in a way
# that can be used to implement private methods more cleanly

_bind = (fn, me) ->
  () ->
    fn.apply(me, arguments)

module.exports = (privateCollection, instance) ->
  for key, func of privateCollection
    if typeof(func) == "function"
      privateCollection[key] = _bind(func, instance)
