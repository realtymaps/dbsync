Promise = require 'bluebird'
path = require 'path'
fs = require 'fs'
stream = require 'stream'
knex = require 'knex'
_ = require 'lodash'
glob = require 'glob'
SqlParser = require './simpleSqlParser'
streamLoader = require './streamLoader'
loggerFactory = require('./logger')

fsStatPromise = Promise.promisify(fs.stat, fs)
fsReaddirPromise = Promise.promisify(fs.readdir, fs)
globPromise = Promise.promisify(glob)


validateNumber = (value, options={}) ->
  type = typeof(value)
  if value == '' || (type != 'string' and type != 'number')
    return false
  numvalue = +value
  if isNaN(numvalue)
    return false
  if options.integer && numvalue != Math.floor(numvalue)
    return false
  if options.min? && numvalue < options.min || options.max? && numvalue > options.max
    return false
  return true

validateOptions = (optionsToCheck) ->
  # don't check the 'logging' value here, it will check itself elsewhere

  if optionsToCheck["on-read-error"]? && ["ignore", "log", "exit"].indexOf(optionsToCheck["on-read-error"]) == -1
    throw "invalid value for 'on-read-error': '#{optionsToCheck["on-read-error"]}'"

  if optionsToCheck["command-buffering"]? && !validateNumber(optionsToCheck["command-buffering"],
      min: 1
      integer: true)
    throw "positive integer required for 'command-buffering', got: '#{optionsToCheck["command-buffering"]}'"

  if optionsToCheck.reminder? && !validateNumber(optionsToCheck.reminder, min: 0)
    throw "non-negative integer required for 'reminder', got: '#{optionsToCheck.reminder}'"

  if optionsToCheck["migration-at-once"] && optionsToCheck["autocommit"]
    throw "'migration-at-once' and 'autocommit' may not be used together"

  if optionsToCheck["one-transaction"] && optionsToCheck["autocommit"]
    throw "'one-transaction' and 'autocommit' may not be used together"

  if optionsToCheck.order? && ["basename", "path"].indexOf(optionsToCheck.order) == -1
    throw "invalid value for 'order': '#{optionsToCheck.order}'"

    
defaults =
  table: 'dbsync_migrations'
  files: '*.sql'
  logging: 'info'
  order: 'path'
  "on-read-error": 'exit'
  "command-buffering": 4
  encoding: 'utf8'
  reminder: 0


module.exports = class Migrator

  # note: this is a static property of the class, not an instance property
  @defaults: defaults

  constructor: (_options) ->
    @name = "Migrator"
    validateOptions(_options) # throws if there is a problem
    options = _.clone(_options)
    _.defaults(options, defaults)
    if !options['dollar-quoting']?
      options['dollar-quoting'] = (options.client == 'pg')
    logger = loggerFactory.getLogger(options.logging)
    logger.debug "STATUS: received migration options: #{JSON.stringify(options,null,2)}"
    @executionContext =
      successes: []
      failure: null
      batchId: Date.now().toString(36)
      currentMigration: null
      files: null
    db = null
    globalTransaction = null
    reminderInterval = null
  
    initializeDbNoLeaks = (handler) =>
      Promise.try () =>
        knex
          client: options.client
          connection: options.connection
          pool:
            min: 0
            max: 1
      .then (_db) =>
        db = _db
        db.schema.hasTable(options.table)
        .then (initialized) =>
          @executionContext.neededInit = !initialized
          if initialized || options.forget
            return Promise.resolve()
          logger.info("STATUS: initializing #{options.table} table")
          if options.test
            return Promise.resolve()
          db.schema.createTable options.table, (table) =>
            table.increments("id").primary()
            table.text("migration_id").notNullable()
            table.text("batch_id").notNullable()
            table.timestamp("started", true).notNullable()
            table.integer("duration_ms").defaultTo(0).notNullable()
            table.text("status").notNullable()
            table.integer("lines_completed")
            table.integer("commands_completed")
            table.text("error_command")
            table.text("error_message")
          .then () =>
            db(options.table)
            .insert
              migration_id: "<< dbsync init >>"
              batch_id: @executionContext.batchId
              started: @executionContext.started
              status: "success"
        .then () =>
          if options["one-transaction"]
            handlerPromise = db.transaction (transaction) =>
              globalTransaction = transaction
              handler()
          else
            handlerPromise = handler()
          return handlerPromise
        .finally () =>
          logger.debug "STATUS: closing database connection"
          db.destroy()

    logReminderOutput = () =>
      logger.log("REMINDER: Currently executing migration '#{@executionContext.currentMigration.migrationId}',
                  command #{@executionContext.currentMigration.commandsCompleted+1}")
          
    getMigrationModsString = () =>
      migrationMods = []
      if options.blindly then migrationMods.push("blind")
      if options.forget then migrationMods.push("forgotten")
      if options.autocommit then migrationMods.push("autocommit")
      if options.test then migrationMods = ["fake"]
      migrationModsStr = " "+migrationMods.join(", ")
      if migrationMods.length
        migrationModsStr += " "
      return migrationModsStr
  
    handleMigrationStream = (client, migrationStream) =>
      if options["migration-at-once"]
        parserPromise = streamLoader(migrationStream, options)
        .then (data) =>
          client.raw(data)
      else
        parser = new SqlParser(migrationStream, options)
        parserPromise = parser.getCommands (commandInfo) =>
          #logger.debug("COMMAND: #{commandInfo.command}")
          @executionContext.currentMigration.currentCommand = commandInfo.command
          @executionContext.currentMigration.commandsCompleted = commandInfo.commandNumber-1
          @executionContext.currentMigration.linesCompleted = commandInfo.lineNumber-1
          client.raw(commandInfo.command.replace(/\?/g,'\\?'))
  
      parserPromise.then () =>
        # at this point, all the commands for this migration are done -- but we still need to update the
        # dbsync table to mark it as done
        @executionContext.currentMigration.currentCommand = null
        @executionContext.currentMigration.stopped = new Date()
        @executionContext.currentMigration.duration = @executionContext.currentMigration.stopped.getTime() - @executionContext.currentMigration.started.getTime()
        if options.forget
          return Promise.resolve()
        else
          return client(options.table).where(id: @executionContext.currentMigration.rowId).update
            duration_ms: @executionContext.currentMigration.duration
            status: "success"
            commands_completed: @executionContext.currentMigration.commandsCompleted
            lines_completed: @executionContext.currentMigration.linesCompleted
  
    handleMigrationFailure = (err) =>
      if reminderInterval?
        clearInterval(reminderInterval)
        reminderInterval = null
        
      if err == "skip"
        # not a really error, just chose to skip out of the migration for some reason
        return Promise.resolve()
        
      # we hit a problem somewhere
      @executionContext.currentMigration.stopped = new Date()
      @executionContext.currentMigration.duration = @executionContext.currentMigration.stopped.getTime() - @executionContext.currentMigration.started.getTime()
      @executionContext.failure = @executionContext.currentMigration
      # try to update the db to record some info about the failure, but since we know something bad already
      # happened we need to swallow any errors that occur trying to do the dbsync update
      if options.forget
        failurePromise = Promise.resolve()
      else
        failurePromise = db(options.table).where(id: @executionContext.currentMigration.rowId).update
          duration_ms: @executionContext.currentMigration.duration
          status: "failure"
          lines_completed: @executionContext.currentMigration.linesCompleted
          commands_completed: @executionContext.currentMigration.commandsCompleted
          error_command: @executionContext.currentMigration.currentCommand
          error_message: ''+err
      failurePromise.then () =>
        @executionContext.failure.reported = true
        if options["one-transaction"]
          db(options.table).where(batch_id: @executionContext.batchId, status: "pending").update
            status: "rollback"
          .then () =>
            Promise.reject(err)
        else
          Promise.reject(err)
      .catch (err2) =>
        # just swallow this error; we'll know the db update failed because @executionContext.failure.reported
        # will be falsy, so we can report it elsewhere -- we'll just pass out the original error
        Promise.reject(err)
  
    handleMigration = (migrationId, migrationSource) =>
      # first check if we need to do this migration
      @shouldMigrationRun(migrationId)
      .then (needsToRun) =>
        if !needsToRun
          return Promise.reject("skip")
  
        # prep to do migration
        @executionContext.currentMigration =
          started: new Date()
          migrationId: migrationId
  
        logger.info("MIGRATION: attempting" +getMigrationModsString()+ "migration for '#{migrationId}'")
        if options.test
          # short-circuit out without actually doing anything
          @executionContext.successes.push(@executionContext.currentMigration)
          return Promise.reject("skip")
          
      .then () =>
        # put something in the db about what we're going to attempt, just in case something happens so we can't
        # update the db if it fails (like if connection to db is lost)
        if options.forget
          return Promise.resolve()
        else
          return db(options.table).insert
            migration_id: migrationId
            batch_id: @executionContext.batchId
            started: @executionContext.currentMigration.started
            status: "pending"
          , 'id'
  
      .then (rowId) =>
        if rowId?
          @executionContext.currentMigration.rowId = parseInt(rowId[0])
        if !migrationSource?
          # no content passed, so we need to get a file stream from the migrationId
          logger.debug("MIGRATION: reading from file #{path.resolve(options.path+'/'+migrationId)}")
          migrationSource = fs.createReadStream(path.resolve(options.path+'/'+migrationId), encoding: options.encoding)
        else if typeof(migrationSource) == 'function'
          # this is to allow for migrations which take some effort to acquire (FTP, etc); we will only do the work
          # encapsulated by the passed function if we get to this point (i.e. if we're going to run the migration)
          logger.debug("MIGRATION: calling function to resolve stream for #{migrationId}")
          migrationSource = migrationSource()
        # at this point, migrationSource should be a stream, a string, or a promise to one of those
        return migrationSource
          
      .then (migrationContent) =>
        if migrationContent instanceof stream.Readable
          # content is already a stream, use it directly
          return migrationContent
        else if typeof(migrationContent) == 'string'
          # turn string into a stream for consistency
          logger.debug("MIGRATION: creating stringStream for #{migrationId}")
          stringStream = new stream.Readable
          stringStream.push(migrationContent)
          stringStream.push(null)
          return stringStream
        else
          # wtf did we get?
          return Promise.reject("bad migration content received")
          
      .then (migrationStream) =>
        if options.reminder
          reminderInterval = setInterval(logReminderOutput, Math.floor(options.reminder*60*1000))
        if options.autocommit
          # don't use a transaction, so each command will be committed individually
          return handleMigrationStream(db, migrationStream)
        else if options["one-transaction"]
          # use the global transaction so the entire group of migrations can be wrapped in a single transaction call
          return handleMigrationStream(globalTransaction, migrationStream)
        else
          # run everything in this migration as part of a single transaction, which will be rolled back if the
          # promise returned from the handler is rejected, or committed if it resolves
          return db.transaction (transaction) =>
            handleMigrationStream(transaction, migrationStream)
            
      .then () =>
        # transaction complete and committed
        if reminderInterval?
          clearInterval(reminderInterval)
          reminderInterval = null
        logger.info("MIGRATION: completed in #{@executionContext.currentMigration.duration/1000}s")
        @executionContext.successes.push(@executionContext.currentMigration)
        
      .catch(handleMigrationFailure)        
     
    handleExecutionSuccess = () =>
      # OK! we've finished scanning the files and are completely done
      if @executionContext.started
        @executionContext.stopped = new Date()
        @executionContext.duration = @executionContext.stopped.getTime() - @executionContext.started.getTime()
      if !@executionContext.successes.length
        logger.info("SUCCESS: no migrations needed")
      else
        if options.test
          logger.info("SUCCESS: #{@executionContext.successes.length} migrations would have been performed")
        else if @executionContext.started
          logger.info("SUCCESS: #{@executionContext.successes.length} migrations performed (#{@executionContext.duration/1000}s total execution)")
        else
          logger.info("SUCCESS: #{@executionContext.successes.length} migrations performed")
      @executionContext.currentMigration = null
      return @executionContext
    
    handleExecutionFailure = (err) =>
      if @executionContext.started
        @executionContext.stopped = new Date()
        @executionContext.duration = @executionContext.stopped.getTime() - @executionContext.started.getTime()
      if @executionContext.failure
        logger.error("FAILURE: failed while migrating '#{@executionContext.failure.migrationId}' after #{@executionContext.failure.duration/1000}s")
        if !@executionContext.failure.reported
          logger.error "FAILURE: additionally, dbsyc failed to update #{options.table} after migration failure"
        if @executionContext.started
          logger.info("FAILURE: #{@executionContext.successes.length} migrations performed successfully before failure")
      else
        @executionContext.failure = {}
      if @executionContext.started
        logger.info("FAILURE: execution took #{@executionContext.duration/1000}s total")
      @executionContext.failure.error = err
      if @executionContext.failure.commandsCompleted?
        logger.error("ERROR: during command #{@executionContext.failure.commandsCompleted+1} beginning on line #{@executionContext.failure.linesCompleted+1}:")
        logger.error(@executionContext.failure.currentCommand)
      if options["stack-traces"]
        logger.error "ERROR: #{err.stack||err}"
      else
        logger.error "ERROR: #{err}"
      @executionContext.currentMigration = null
      Promise.reject(@executionContext)
  
    @scanForFiles = () => Promise.try () =>
      if typeof(options.path) != "string" || options.path.length == 0
        return Promise.reject("bad scan path")
  
      scanPath = path.resolve(options.path)
      fsStatPromise(scanPath)
      .then (stats) =>
        if !stats.isDirectory()
          return Promise.reject("scan path is not a directory: #{scanPath}")
        fsReaddirPromise(scanPath)
      .catch (err) =>
        logger.error err
        return Promise.reject("scan path doesn't exist, or isn't readable: #{scanPath}")
      .then () =>
        logger.debug "STATUS: scanning #{scanPath}"
        if !_.isArray(options.files)
          globs = [options.files]
        else
          globs = options.files
        Promise.resolve(globs).map (fileGlob) =>
          globPromise fileGlob,
            cwd: scanPath
            nosort: true  # don't bother, because we have to do it ourselves
            silent: options["on-read-error"] != "ignore"
            strict: options["on-read-error"] == "exit"
            nocase: !options["case-sensitive"]
            matchBase: !!options.recursive
            nocomment: true
            nodir: true
      .then (fileLists) =>
        allFiles = _.flatten(fileLists)
        if options.ordering == "basename"
          sorter = (filepath) => path.basename(filepath)
        else
          sorter = undefined
        return _.sortBy(allFiles, sorter)
  
    @shouldMigrationRun = (migrationId) => Promise.try () =>
      if options.blindly || @executionContext.neededInit && options.forget
        # don't actually do the check, we want to run the migration no matter what
        return true
      else
        db(options.table)
        .select()
        .where(migration_id: migrationId, status: "success")
        .then (results) =>
          if results?.length
            # migration previously succeeded
            return false
          else
            # no previous success found
            return true
      
    @doAllMigrationsIfNeeded = () =>
      @executionContext.started = new Date()
      initializeDbNoLeaks () =>
        if !@executionContext.files?
          fileListPromise = @scanForFiles()
          .then (files) =>
            @executionContext.files = files
        else
          fileListPromise = Promise.resolve(@executionContext.files)
    
        fileListPromise.then (files) =>
          migrationPromiseChain = Promise.resolve()
          files.forEach (filename) =>
            # we want to do the migrations serially, not in parallel
            migrationPromiseChain = migrationPromiseChain
            .then () =>
              handleMigration(filename)
          return migrationPromiseChain
      .then(handleExecutionSuccess)
      .catch(handleExecutionFailure)
  
    @doSingleMigrationIfNeeded = (migrationId, migrationSource) =>
      @executionContext.started = null
      @executionContext.duration = null
      initializeDbNoLeaks () =>
        handleMigration(migrationId, migrationSource)
      .then(handleExecutionSuccess)
      .catch(handleExecutionFailure)
