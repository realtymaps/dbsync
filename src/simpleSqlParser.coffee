Promise = require 'bluebird'


# state names
COMMAND = 'command'
DOUBLE_QUOTE_STRING = 'double-quote string'
SINGLE_QUOTE_STRING = 'single-quote string'
DOLLAR_QUOTE_STRING_OPEN_TAG = 'dollar-quote string open tag'
DOLLAR_QUOTE_STRING = 'dollar-quote string'
MAYBE_DOLLAR_QUOTE_STRING_CLOSE_TAG = 'maybe dollar-quote string close tag'
SINGLE_LINE_COMMENT = 'single-line comment'
MULTI_LINE_COMMENT = 'multi-line comment'


class SimpleSqlParser

  constructor: (@sqlStream, options={}) ->
    @name = 'SimpleSqlParser'
    @options =
      dollar: options["dollar-quoting"]
      queueSize: +options["command-buffering"]
    @residual = ''
    @linesCompleted = 0
    @commandNumber = 0
    @lineCommandStartedOn = 0
    @commandQueue = []
    @waitingForQueue = false
    @waitingForStreamedCommand = true
    @streamDone = false
    @state = COMMAND
    @importantCharsState = 0
    @lastChar = ''
    @dollarOpenTag = ''
    @dollarCloseTag = ''

  getLinesParsed: () =>
    @linesCompleted
    
  getCommandsParsed: () =>
    @commandNumber

  getCommands: (commandCallback) => new Promise (resolve, reject) =>
    handleError = (err) =>
      if @state == 'error'
        return
      @state = 'error'
      reject(err)
    
    handleImportantChar = (newState) =>
      if newState?
        @state = newState
      if @importantCharsState == 0
        @offset = @i
        @residual = ''
        @lineCommandStartedOn = @linesCompleted+1
      @importantCharsState++
      
    handleQueuedCommand = () =>
      if @state == 'error'
        return

      if @commandQueue.length > 0
        @waitingForStreamedCommand = false
        commandCallback(@commandQueue.shift())
        .then handleQueuedCommand
        .catch handleError
      else
        if @streamDone
          if @importantCharsState == 0
            resolve()
          else
            # this should be impossible to reach, as we would expect the prior "command" to fail when executed
            handleError("unexpected EOF in migration")
        else
          @waitingForStreamedCommand = true
    
      if @waitingForQueue && @commandQueue.length < @options.queueSize
        @waitingForQueue = false
        @sqlStream.resume()
      
    parseMore = (buf) =>
      if @state == 'error'
        return
        
      @offset = 0
      @i=0
      while @i < buf.length
        char = buf.charAt(@i)
        if char == '\n'
          @linesCompleted++
          
        switch @state
          when DOUBLE_QUOTE_STRING
            if char == '"'
              @state = COMMAND
          when SINGLE_QUOTE_STRING
            if char == "'"
              @state = COMMAND
          when SINGLE_LINE_COMMENT
            if char == '\n'
              @state = COMMAND
          when MULTI_LINE_COMMENT
            if @lastChar == '*' && char == '/'
              @state = COMMAND
          when DOLLAR_QUOTE_STRING_OPEN_TAG
            if char == '$'
              @state = DOLLAR_QUOTE_STRING
            else
              @dollarOpenTag += char
          when DOLLAR_QUOTE_STRING
            if char == '$'
              @state = MAYBE_DOLLAR_QUOTE_STRING_CLOSE_TAG
              @dollarCloseTag = ''
          when MAYBE_DOLLAR_QUOTE_STRING_CLOSE_TAG
            if char == '$'
              if @dollarCloseTag == @dollarOpenTag
                @state = COMMAND
              else
                # maybe /now/ we're starting the real close tag
                @dollarCloseTag = ''
            else
              @dollarCloseTag += char
          when COMMAND
            switch
              when char == ';'
                @commandNumber++
                @commandQueue.push
                  command: @residual + buf.slice(@offset, @i+1)
                  commandNumber: @commandNumber
                  lineNumber: @lineCommandStartedOn
                @offset = @i+1
                @residual = ''
                @importantCharsState = 0
                if @waitingForStreamedCommand
                  # this kicks off a promise chain that keeps processing commands until the queue runs dry
                  handleQueuedCommand()
              when char == '"'
                handleImportantChar(DOUBLE_QUOTE_STRING)
              when char == "'"
                handleImportantChar(SINGLE_QUOTE_STRING)
              when char == '$' && !@lastChar.match(/[\w$]/) && @options.dollar
                handleImportantChar(DOLLAR_QUOTE_STRING_OPEN_TAG)
                @dollarOpenTag = ''
              when @lastChar == '-' && char == '-'
                @state = SINGLE_LINE_COMMENT
                # retroactively count the prior character as unimportant
                @importantCharsState--
              when @lastChar == '/' && char == '*'
                @state = MULTI_LINE_COMMENT
                # retroactively count the prior character as unimportant
                @importantCharsState--
              when char.match(/\S/)
                handleImportantChar()
              else
              # don't do anything for whitespace
        
        @lastChar = char
        @i++
                    
      # push the rest of the buffer onto the residual
      @residual += buf.slice(@offset)

    @sqlStream.on 'data', (chunk) =>
      parseMore(chunk)
      if @commandQueue.length >= @options.queueSize
        @waitingForQueue = true
        @sqlStream.pause()

    @sqlStream.on 'end', () =>
      @streamDone = true
      @commandQueue.push
        command: @residual.trimRight()
        commandNumber: @commandNumber
        lineNumber: @lineCommandStartedOn
      if @waitingForStreamedCommand
        handleQueuedCommand()
        
    @sqlStream.on 'error', handleError


module.exports = SimpleSqlParser
