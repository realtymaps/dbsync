Promise = require 'bluebird'


module.exports = (inStream) -> new Promise (resolve, reject) ->
  
  chunks = []

  inStream.on 'data', (chunk) ->
    chunks.push(chunk)

  inStream.on 'end', () ->
      resolve(chunks.join(''))

  inStream.on 'error', (err) ->
      reject(err)
