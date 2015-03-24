_ = require 'lodash'
Promise = require 'bluebird'
Migrator = require('./migrator')


optionSpecs =
  path:
    alias: "p"
    required: true
    requiresArg: true
    describe: "Directory to scan for migration files; this part of the file path will not be used when determining
              whether a migration has been run before."
  client:
    alias: "db"
    required: true
    requiresArg: true
    describe: "A db client string, as appropriate to pass to knex in the initialization object:
                  http://knexjs.org/#Installation-client"
  connection:
    alias: "conn"
    required: true
    requiresArg: true
    describe: "Additional db connection options, as appropriate to pass to knex in the initialization object:
              http://knexjs.org/#Installation-client  In order to set subproperties, use dot notation as in these
              examples:
              \n    --client=pg --connection=postgres://usr:pw@host:port/dbname?opts
              \n    --client=mysql --connection.user=usr --connection.host=localhost
              \n    --client=sqlite3 --connection.filename=./mydb.sqlite"
  table:
    alias: "t"
    requiresArg: true
    describe: "Table name for tracking migrations"
  files:
    requiresArg: true
    describe: "Glob pattern used to filter which files in the path are treated as migrations.  May be specified multiple
              times, in which case files matching any of the globs will be treated as migrations."
  encoding:
    alias: "e"
    requiresArg: true
    describe: "Encoding to use when reading files."
  "case-sensitive":
    alias: "c"
    boolean: true
    describe: "If set, the glob pattern will be matched against files as a case-sensitive pattern."
  recursive:
    alias: "r"
    boolean: true
    describe: "If set, subdirectories within the path will be traversed and searched for migrations matching the
              filter pattern; this option is ignored if the files glob option contains a slash character."
  order:
    alias: "o"
    requiresArg: true
    describe: "Governs whether migrations are ordered based on the file's basename alone, or the full file path; must
              be one of: basename, path"
  logging:
    alias: "l"
    requiresArg: true
    describe: "Logging verbosity; must be one of: debug, info, warn, error, silent"
  "on-read-error":
    describe: "Governs behavior when an unusual directory read error is encountered; must be one of: ignore, log, exit"
  test:
    boolean: true
    describe: "If set, instead of performing migrations, dbsync will simply log any messages about actions it would have
              performed normally."
  autocommit:
    boolean: true
    describe: "If set, the commands in the migrations will be run and committed individually, rather than wrapping each
              migration inside a single transaction; this is useful if you want to manually manage multiple transactions
              within a migration, or if you want to execute commands not allowed within a transaction (like DROP
              DATABASE).  This option conflicts with --migration-at-once and --one-transaction."
  "migration-at-once":
    boolean: true
    describe: "If set, dbsync will not count lines or commands, but instead will load each migration entirely into
              memory and pass it to the db at once.  This will keep dbsync from processing the text of the migration,
              but might require a lot of memory for large migrations.  This option conflicts with --autocommit."
  "one-transaction":
    boolean: true
    alias: "1"
    describe: "If set, dbsync will run all the migrations as a single transaction, rather than one transaction per
              migration.  Migration table initialization, and updates to the migration table for pending and failed
              migrations will not be executed as part of this transaction.  This option conflicts with --autocommit."
  forget:
    boolean: true
    describe: "If set, dbsync will not record any migrations that it performs during this run, nor will it create
              the migrations table if it doesn't yet exist, but it will still refuse to run migrations that have
              succeeded previously (unless --blindly is also used); this is useful for scripting misc db commands
              without requiring any additional client tools to be installed."
  blindly:
    boolean: true
    describe: "If set, dbsync will not restrict the migrations performed to only those that have not run successfully
              before; this is useful for rerunning previously-run scripts during development, or for scripting misc db
              commands without requiring any additional client tools to be installed."
  reminder:
    requiresArg: true
    describe: "Some environments where dbsync may run (e.g. CircleCI) require periodic output to ensure the process is
              running properly.  Sometimes a migration could take a long time, but without this indicating a problem.
              In such cases, you can use --reminder to request reminder output every X minutes (a best-effort attempt is
              made, so to be safe you should set a lower value than you really need); a value of 0 disables reminder
              outout.  Value must be non-negative, but can be a decimal (e.g. --reminder .5)"
  "dollar-quoting":
    describe: "If set, this will force dbsync to allow dollar-quoted strings as specified by PostgreSQL. The negation,
              --no-dollar-quoting, is also available to force quoting to be turned off (this may make a minor
              improvement to resource usage by dbsync).  The default value for this option is true when --client is set
              to 'pg', and false otherwise.  This is not relevant when --migration-at-once is also used.  For more
              details on dollar-quoting, see section 4.1.2.4 (Dollar-quoted String Constants) of
              http://www.postgresql.org/docs/9.3/static/sql-syntax-lexical.html"
  "command-buffering":
    requiresArg: true
    describe: "This sets the number of SQL commands to buffer before pausing reading from the file; must be a positive
              integer. This is a performance-tuning option and shouldn't need to be altered for most use cases."
  "stack-traces":
    boolean: true
    describe: "If set, stack traces will be logged with any errors (when present)."


module.exports = run: Promise.try () ->
  columns = Math.min(process.stdout.columns||80, 100)
  wrap = require("wordwrap")(columns)
  
  args = require('yargs')
    .strict()
    .usage wrap("Scans a path for files to run as SQL migrations.  Migrations found which have not been (successfully) run
                before will be run in ascending order based on path/filename.\n\nUsage: dbsync [options]")
    .showHelpOnFail(false, "Use --help for available options")
    .wrap(columns)
    .help('help').alias('help', 'h')
    .options(optionSpecs)
    .default(Migrator.defaults)
    .argv

  try
    migrator = new Migrator(_.pick(args, _.keys(optionSpecs)))
    migrator.doAllMigrationsIfNeeded()
    .then () ->
      process.exit(0)
    .catch (err) ->
      # not logging this error here because it would have already been logged internally
      process.exit(2)
  catch err
    # we do have to do logging here though
    if args.logging != "silent"
      console.error "FAILURE: could not instantiate migrator; use --help for options details"
      console.error "ERROR: #{err}"
    process.exit(3)
