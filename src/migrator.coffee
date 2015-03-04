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
bindPrivateMethods = require('./bindPrivateMethods')

defaults =
  table: 'dbsync_migrations'
  files: '*.sql'
  logging: 'info'
  order: 'path'
  "on-read-error": 'exit'
  "command-buffering": 4
  encoding: 'utf8'

fsStatPromise = Promise.promisify(fs.stat, fs)
fsReaddirPromise = Promise.promisify(fs.readdir, fs)
globPromise = Promise.promisify(glob)


isPositiveInteger = (value) ->
  type = typeof(value)
  if value == '' || (type != 'string' and type != 'number')
    return false
  numvalue = +value
  if isNaN(numvalue) || numvalue != Math.floor(numvalue) || numvalue <= 0
    return false
  return true

module.exports = class Migrator
  _$ = {}

  constructor: (_options) ->
    bindPrivateMethods(_$, this)
    @name = "Migrator"
    _$.validateOptions(_options) # throws if there is a problem
    _$.options = _.clone(_options)
    _.defaults(_$.options, defaults)
    _$.logger = loggerFactory.getLogger(_$.options.logging)
    _$.logger.debug "STATUS: received migration _$.options: #{JSON.stringify(_$.options,null,2)}"
    @executionContext =
      successes: []
      failure: null
      batchId: Date.now().toString(36)
      currentMigration: null
      files: null
     
  # note: this is a static property of the class, not an instance property
  @defaults: defaults

  _$.validateOptions: (optionsToCheck) ->
    # don't check the 'logging' value here, it will check itself elsewhere

    if ["ignore", "log", "exit"].indexOf(optionsToCheck["on-read-error"]) == -1
      throw "invalid value for 'on-read-error': '#{optionsToCheck["on-read-error"]}'"

    if !isPositiveInteger(optionsToCheck["command-buffering"])
      throw "positive integer required for 'command-buffering', got: '#{optionsToCheck["command-buffering"]}'"

    if optionsToCheck["migration-at-once"] && optionsToCheck["autocommit"]
      throw "'migration-at-once' and 'autocommit' may not be used together"

    if optionsToCheck["one-transaction"] && optionsToCheck["autocommit"]
      throw "'one-transaction' and 'autocommit' may not be used together"

    if ["basename", "path"].indexOf(optionsToCheck.order) == -1
      throw "invalid value for 'order': '#{optionsToCheck.order}'"

  _$.initializeDbNoLeaks = (handler) ->
    Promise.try () =>
      knex
        client: _$.options.client
        connection: _$.options.connection
        pool:
          min: 0
          max: 1
    .then (db) =>
      _$.db = db
      db.schema.hasTable(_$.options.table)
      .then (initialized) =>
        @executionContext.neededInit = !initialized
        if initialized || _$.options.forget
          return Promise.resolve()
        _$.logger.info("STATUS: initializing #{_$.options.table} table")
        if _$.options.test
          return Promise.resolve()
        db.schema.createTable _$.options.table, (table) =>
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
          db(_$.options.table)
          .insert
            migration_id: "<< dbsync init >>"
            batch_id: @executionContext.batchId
            started: @executionContext.started
            status: "success"
      .then () =>
        if _$.options["one-transaction"]
          handlerPromise = db.transaction (transaction) =>
            _$.globalTransaction = transaction
            handler()
        else
          handlerPromise = handler()
        return handlerPromise
      .finally () =>
        _$.logger.debug "STATUS: closing database connection"
        db.destroy()
        
  _$.getMigrationModsString = () ->
    migrationMods = []
    if _$.options.blindly then migrationMods.push("blind")
    if _$.options.forget then migrationMods.push("forgotten")
    if _$.options.autocommit then migrationMods.push("autocommit")
    if _$.options.test then migrationMods = ["fake"]
    migrationModsStr = " "+migrationMods.join(", ")
    if migrationMods.length
      migrationModsStr += " "
    return migrationModsStr

  _$.handleMigrationStream = (client, migrationStream) ->
    if _$.options["migration-at-once"]
      parserPromise = streamLoader(migrationStream, _$.options)
      .then (data) =>
        client.raw(data)
    else
      parser = new SqlParser(migrationStream, _$.options)
      parserPromise = parser.getCommands (commandInfo) =>
        #_$.logger.debug("COMMAND: #{commandInfo.command}")
        @executionContext.currentMigration.currentCommand = commandInfo.command
        @executionContext.currentMigration.commandsCompleted = commandInfo.commandNumber-1
        @executionContext.currentMigration.linesCompleted = commandInfo.lineNumber-1
        client.raw(commandInfo.command)

    parserPromise.then () =>
      # at this point, all the commands for this migration are done -- but we still need to update the
      # dbsync table to mark it as done
      @executionContext.currentMigration.currentCommand = null
      @executionContext.currentMigration.stopped = new Date()
      @executionContext.currentMigration.duration = @executionContext.currentMigration.stopped.getTime() - @executionContext.currentMigration.started.getTime()
      if _$.options.forget
        return Promise.resolve()
      else
        return client(_$.options.table).where(id: @executionContext.currentMigration.rowId).update
          duration_ms: @executionContext.currentMigration.duration
          status: "success"
          commands_completed: @executionContext.currentMigration.commandsCompleted
          lines_completed: @executionContext.currentMigration.linesCompleted

  _$.handleMigrationFailure = (err) ->
    if err == "skip"
      # not a really error, just chose to skip out of the migration for some reason
      return Promise.resolve()
      
    # we hit a problem somewhere
    @executionContext.currentMigration.stopped = new Date()
    @executionContext.currentMigration.duration = @executionContext.currentMigration.stopped.getTime() - @executionContext.currentMigration.started.getTime()
    @executionContext.failure = @executionContext.currentMigration
    # try to update the db to record some info about the failure, but since we know something bad already
    # happened we need to swallow any errors that occur trying to do the dbsync update
    if _$.options.forget
      failurePromise = Promise.resolve()
    else
      failurePromise = _$.db(_$.options.table).where(id: @executionContext.currentMigration.rowId).update
        duration_ms: @executionContext.currentMigration.duration
        status: "failure"
        lines_completed: @executionContext.currentMigration.linesCompleted
        commands_completed: @executionContext.currentMigration.commandsCompleted
        error_command: @executionContext.currentMigration.currentCommand
        error_message: ''+err
    failurePromise.then () =>
      @executionContext.failure.reported = true
      if _$.options["one-transaction"]
        _$.db(_$.options.table).where(batch_id: @executionContext.batchId, status: "pending").update
          status: "rollback"
        .then () =>
          Promise.reject(err)
      else
        Promise.reject(err)
    .catch (err2) =>
      # just swallow this error; we'll know the db update failed because @executionContext.failure.reported
      # will be falsy, so we can report it elsewhere -- we'll just pass out the original error
      Promise.reject(err)

  _$.handleMigration = (migrationId, migrationSource) ->
    # first check if we need to do this migration
    @shouldMigrationRun(migrationId)
    .then (needsToRun) =>
      if !needsToRun
        return Promise.reject("skip")

      # prep to do migration
      @executionContext.currentMigration =
        started: new Date()
        migrationId: migrationId

      _$.logger.info("MIGRATION: attempting" +_$.getMigrationModsString()+ "migration for '#{migrationId}'")
      if _$.options.test
        # short-circuit out without actually doing anything
        @executionContext.successes.push(@executionContext.currentMigration)
        return Promise.reject("skip")
        
    .then () =>
      # put something in the db about what we're going to attempt, just in case something happens so we can't
      # update the db if it fails (like if connection to db is lost)
      if _$.options.forget
        return Promise.resolve()
      else
        return _$.db(_$.options.table).insert
          migration_id: migrationId
          batch_id: @executionContext.batchId
          started: @executionContext.currentMigration.started
          status: "pending"
        , 'id'

    .then (rowId) =>
      @executionContext.currentMigration.rowId = parseInt(rowId[0])
      if !migrationSource?
        # no content passed, so we need to get a file stream from the migrationId
        _$.logger.debug("MIGRATION: reading from file #{path.resolve(_$.options.path+'/'+migrationId)}")
        migrationSource = fs.createReadStream(path.resolve(_$.options.path+'/'+migrationId), encoding: _$.options.encoding)
      else if typeof(migrationSource) == 'function'
        # this is to allow for migrations which take some effort to acquire (FTP, etc); we will only do the work
        # encapsulated by the passed function if we get to this point (i.e. if we're going to run the migration)
        _$.logger.debug("MIGRATION: calling function to resolve stream for #{migrationId}")
        migrationSource = migrationSource()
      # at this point, migrationSource should be a stream, a string, or a promise to one of those
      return migrationSource
        
    .then (migrationContent) =>
      if migrationContent instanceof stream.Readable
        # content is already a stream, use it directly
        return migrationContent
      else if typeof(migrationContent) == 'string'
        # turn string into a stream for consistency
        _$.logger.debug("MIGRATION: creating stringStream for #{migrationId}")
        stringStream = new stream.Readable
        stringStream.push(migrationContent)
        stringStream.push(null)
        return stringStream
      else
        # wtf did we get?
        return Promise.reject("bad migration content received")
        
    .then (migrationStream) =>
      if _$.options.autocommit
        # don't use a transaction, so each command will be committed individually
        return _$.handleMigrationStream(_$.db, migrationStream)
      else if _$.options["one-transaction"]
        # use the global transaction so the entire group of migrations can be wrapped in a single transaction call
        return _$.handleMigrationStream(_$.globalTransaction, migrationStream)
      else
        # run everything in this migration as part of a single transaction, which will be rolled back if the
        # promise returned from the handler is rejected, or committed if it resolves
        return _$.db.transaction (transaction) =>
          _$.handleMigrationStream(transaction, migrationStream)
          
    .then () =>
      # transaction complete and committed
      _$.logger.info("MIGRATION: completed in #{@executionContext.currentMigration.duration/1000}s")
      @executionContext.successes.push(@executionContext.currentMigration)
      
    .catch(_$.handleMigrationFailure)        
   
  _$.handleExecutionSuccess = () ->
    # OK! we've finished scanning the files and are completely done
    if @executionContext.started
      @executionContext.stopped = new Date()
      @executionContext.duration = @executionContext.stopped.getTime() - @executionContext.started.getTime()
    if !@executionContext.successes.length
      _$.logger.info("SUCCESS: no migrations needed")
    else
      if _$.options.test
        _$.logger.info("SUCCESS: #{@executionContext.successes.length} migrations would have been performed")
      else if @executionContext.started
        _$.logger.info("SUCCESS: #{@executionContext.successes.length} migrations performed (#{@executionContext.duration/1000}s total execution)")
      else
        _$.logger.info("SUCCESS: #{@executionContext.successes.length} migrations performed")
    @executionContext.currentMigration = null
    return @executionContext
  
  _$.handleExecutionFailure = (err) ->
    if @executionContext.started
      @executionContext.stopped = new Date()
      @executionContext.duration = @executionContext.stopped.getTime() - @executionContext.started.getTime()
    if @executionContext.failure
      _$.logger.error("FAILURE: failed while migrating '#{@executionContext.failure.migrationId}' after #{@executionContext.failure.duration/1000}s")
      if !@executionContext.failure.reported
        _$.logger.error "FAILURE: additionally, dbsyc failed to update #{_$.options.table} after migration failure"
      if @executionContext.started
        _$.logger.info("FAILURE: #{@executionContext.successes.length} migrations performed successfully before failure")
    else
      @executionContext.failure = {}
    if @executionContext.started
      _$.logger.info("FAILURE: execution took #{@executionContext.duration/1000}s total")
    @executionContext.failure.error = err
    if @executionContext.failure.commandsCompleted?
      _$.logger.error("ERROR: during command #{@executionContext.failure.commandsCompleted+1} beginning on line #{@executionContext.failure.linesCompleted+1}:")
      _$.logger.error(@executionContext.failure.currentCommand)
    if _$.options["stack-traces"]
      _$.logger.error "ERROR: #{err.stack||err}"
    else
      _$.logger.error "ERROR: #{err}"
    @executionContext.currentMigration = null
    Promise.reject(@executionContext)

  scanForFiles: () => Promise.try () =>
    if typeof(_$.options.path) != "string" || _$.options.path.length == 0
      return Promise.reject("bad scan path")

    scanPath = path.resolve(_$.options.path)
    fsStatPromise(scanPath)
    .then (stats) =>
      if !stats.isDirectory()
        return Promise.reject("scan path is not a directory: #{scanPath}")
      fsReaddirPromise(scanPath)
    .catch (err) =>
      _$.logger.error err
      return Promise.reject("scan path doesn't exist, or isn't readable: #{scanPath}")
    .then () =>
      _$.logger.debug "STATUS: scanning #{scanPath}"
      if !_.isArray(_$.options.files)
        globs = [_$.options.files]
      else
        globs = _$.options.files
      Promise.resolve(globs).map (fileGlob) =>
        globPromise fileGlob,
          cwd: scanPath
          nosort: true  # don't bother, because we have to do it ourselves
          silent: _$.options["on-read-error"] != "ignore"
          strict: _$.options["on-read-error"] == "exit"
          nocase: !_$.options["case-sensitive"]
          matchBase: !!_$.options.recursive
          nocomment: true
          nodir: true
    .then (fileLists) =>
      allFiles = _.flatten(fileLists)
      if _$.options.ordering == "basename"
        sorter = (filepath) => path.basename(filepath)
      else
        sorter = undefined
      return _.sortBy(allFiles, sorter)

  shouldMigrationRun: (migrationId) => Promise.try () =>
    if _$.options.blindly || @executionContext.neededInit && _$.options.forget
      # don't actually do the check, we want to run the migration no matter what
      return true
    else
      _$.db(_$.options.table)
      .select()
      .where(migration_id: migrationId, status: "success")
      .then (results) =>
        if results?.length
          # migration previously succeeded
          return false
        else
          # no previous success found
          return true
    
  doAllMigrationsIfNeeded: () =>
    @executionContext.started = new Date()
    _$.initializeDbNoLeaks () =>
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
            _$.handleMigration(filename)
        return migrationPromiseChain
    .then(_$.handleExecutionSuccess)
    .catch(_$.handleExecutionFailure)

  doSingleMigrationIfNeeded: (migrationId, migrationSource) =>
    @executionContext.started = null
    @executionContext.duration = null
    _$.initializeDbNoLeaks () =>
      _$.handleMigration(migrationId, migrationSource)
    .then(_$.handleExecutionSuccess)
    .catch(_$.handleExecutionFailure)
