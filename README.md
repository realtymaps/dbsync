## dbsync

dbsync is a [schema migration / database change management](https://en.wikipedia.org/wiki/Schema_migration) tool,
similar to [flyway](http://flywaydb.org/) but less opinionated and more flexible.

At its most basic level, dbsync is a command line tool that scans a path for files to run as SQL migrations. Migrations
found which have not been (successfully) run before will be run in ascending order based on path/filename. Various
options can be used to change those basic behaviors.

#### Supported databases

dbsync supports any database that [Knex.js](http://knexjs.org/) does.  For now, that means:
* Postgres
* MySQL
* MariaDB
* SQLite3
* and maybe Oracle (mentioned in the Knex docs as experimental support)

#### The db "migration" concept

Any time a change in the code requires a change in the db structure, a transformation of the data, and/or a small
amount of new data to be inserted, it should happen as a SQL "migration".  The following bullets describe migrations
as they are generally used, and the default behaviors for dbsync; however, all of those behaviors can be altered via
the command line options described later.

* Generally, once a migration has been applied to a given database, it will not be applied again to that same database.
* Migration files are not inspected for changes; if the filename is the same as a previously successful migration, it
will not be run again.
* A migration file will either be applied in its entirety or not at all.  If a migration is not applied (due to an
error), no more migrations will be attempted, and the failed migration will be attempted again on next execution.
* Migrations are ordered; they are applied in alphabetical order by filename, including path.

#### Using dbsync to perform migrations

dbsync should be scripted to occur as part of application deploy and/or startup, and so should rarely need to be
initiated independently.

Data should almost always be inserted via INSERT statements, usually with column names, e.g. `INSERT INTO table_name
(col_name_1, col_name_2, ...) VALUES (value1, value2, ...);`

Avoid inserting values into columns that can be auto-generated (like serial ids) – let the column's sequence assign the
value.  If these auto-generated ids need to be used in SQL somewhere else in the migration, it's still best to let the
value get auto-generated, and then just select it later.

## Command line use

In order to use dbsync as a stand-alone utility, you will need to install the appropriate database node client module
(see the [Knex.js documentation](http://knexjs.org/#Installation-node) for supported clients), either locally wherever
dbsync will be used, or globally.

Below are the details of command line options available for dbsync (the same help block can be displayed by running
`dbsync --help`).
```
--help, -h             Show help                                                             
--path, -p             Directory to scan for migration files; this part of the file path
                       will not be used when determining whether a migration has been run
                       before.                                                     [required]
--client, --db         A db client string, as appropriate to pass to knex in the
                       initialization object: http://knexjs.org/#Installation-client
                                                                                   [required]
--connection, --conn   Additional db connection options, as appropriate to pass to knex in
                       the initialization object: http://knexjs.org/#Installation-client  In
                       order to set subproperties, use dot notation as in these
                       examples: 
                       --client=pg --connection=postgres://usr:pw@host:port/dbname?opts 
                       --client=mysql --connection.user=usr --connection.host=localhost 
                       --client=sqlite3 --connection.filename=./mydb.sqlite        [required]
--table, -t            Table name for tracking migrations      [default: "dbsync_migrations"]
--files                Glob pattern used to filter which files in the path are treated as
                       migrations.  May be specified multiple times, in which case files
                       matching any of the globs will be treated as migrations.
                                                                           [default: "*.sql"]
--encoding, -e         Encoding to use when reading files.                  [default: "utf8"]
--case-sensitive, -c   If set, the glob pattern will be matched against files as a
                       case-sensitive pattern.                                               
--recursive, -r        If set, subdirectories within the path will be traversed and searched
                       for migrations matching the filter pattern; this option is ignored if
                       the files glob option contains a slash character.                     
--order, -o            Governs whether migrations are ordered based on the file's basename
                       alone, or the full file path; must be one of: basename, path
                                                                            [default: "path"]
--logging, -l          Logging verbosity; must be one of: debug, info, warn, error, silent
                                                                            [default: "info"]
--on-read-error        Governs behavior when an unusual directory read error is encountered;
                       must be one of: ignore, log, exit                    [default: "exit"]
--test                 If set, instead of performing migrations, dbsync will simply log any
                       messages about actions it would have performed normally.              
--autocommit           If set, the commands in the migrations will be run and committed
                       individually, rather than wrapping each migration inside a single
                       transaction; this is useful if you want to manually manage multiple
                       transactions within a migration, or if you want to execute commands
                       not allowed within a transaction (like DROP DATABASE).  This option
                       conflicts with --migration-at-once and --one-transaction.             
--migration-at-once    If set, dbsync will not count lines or commands, but instead will
                       load each migration entirely into memory and pass it to the db at
                       once.  This will keep dbsync from processing the text of the
                       migration, but might require a lot of memory for large migrations.
                       This option conflicts with --autocommit.                              
--one-transaction, -1  If set, dbsync will run all the migrations as a single transaction,
                       rather than one transaction per migration.  Migration table
                       initialization, and updates to the migration table for pending and
                       failed migrations will not be executed as part of this transaction.
                       This option conflicts with --autocommit.                              
--forget               If set, dbsync will not record any migrations that it performs during
                       this run, nor will it create the migrations table if it doesn't yet
                       exist, but it will still refuse to run migrations that have succeeded
                       previously (unless --blindly is also used); this is useful for
                       scripting misc db commands without requiring any additional client
                       tools to be installed.                                                
--blindly              If set, dbsync will not restrict the migrations performed to only
                       those that have not run successfully before; this is useful for
                       rerunning previously-run scripts during development, or for scripting
                       misc db commands without requiring any additional client tools to be
                       installed.                                                            
--reminder             Some environments where dbsync may run (e.g. CircleCI) require
                       periodic output to ensure the process is running properly.  Sometimes
                       a migration could take a long time, but without this indicating a
                       problem. In such cases, you can use --reminder to request reminder
                       output every X minutes (a best-effort attempt is made, so to be safe
                       you should set a lower value than you really need); a value of 0
                       disables reminder outout.  Value must be non-negative, but can be a
                       decimal (e.g. --reminder .5)                              [default: 0]
--dollar-quoting       If set, this will force dbsync to allow dollar-quoted strings as
                       specified by PostgreSQL. The negation, --no-dollar-quoting, is also
                       available to force quoting to be turned off (this may make a minor
                       improvement to resource usage by dbsync).  The default value for this
                       option is true when --client is set to 'pg', and false otherwise.
                       This is not relevant when --migration-at-once is also used.  For more
                       details on dollar-quoting, see section 4.1.2.4 (Dollar-quoted String
                       Constants) of
                       http://www.postgresql.org/docs/9.3/static/sql-syntax-lexical.html     
--command-buffering    This sets the number of SQL commands to buffer before pausing reading
                       from the file; must be a positive integer. This is a
                       performance-tuning option and shouldn't need to be altered for most
                       use cases.                                                [default: 4]
--stack-traces         If set, stack traces will be logged with any errors (when present).
```

## Programmatic usage

dbsync may also be used programmatically as a node dependency.  All the features available through the command line are
still available when used this way, plus some additional flexibility not available from the command line.

This module is written in [coffeescript](http://coffeescript.org/), but may be used via `require("dbsync")` from either
javascript or coffeescript node apps.  This module uses promises as implemented by
[bluebird](https://github.com/petkaantonov/bluebird).

#### Initialization

`require("dbsync")` returns the Migrator class; you instantiate a Migrator instance with something like:
```
var Migrator = require("dbsync");
var migrator = new Migrator(options);
```
where `options` is an object containing keys just like the argument options described above, subject to the caveats
below:
* The `--help` command line option has no equivalent in the options object.
* Options required for the command line are also required for the options object, except that `path` is not required
if dbsync will not perform migrations based on files.
* Where multiple forms of an argument option are available for the command line, only the first listed works for
programmatic use.
* Options that do not take values will be interpreted as booleans; this is, if the option is given a truthy value, it
will be turned on.
* For options that take values, the same allowed values and defaults apply.
* Options allowing dot notation on the command line (such as `--connection`) correspond to a nested object
* Multiple uses of an option (such as `--files`) correspond to an array of values

Example:
```
dbsync --client=mysql \
       --conn.user=user \
       --connection.host=localhost \
       --files='*.sql' \
       --files='*.pgsql' \
       --case-sensitive
```
will use options equivalent to the following options object:
```
{
  client: 'mysql',
  connection: {
    user: 'user',
    host: 'localhost'
  },
  files: ['*.sql', '*.pgsql'],
  "case-sensitive": true,
  "stack-traces": false   // all booleans default to false, so this is the same as not specifying it
}
```

Note that invalid  options passed to the Migrator constructor could result in thrown errors.

#### Additional options flexibility

In addition to the options allowed from the command line, the following are also available:
* `logging`: passing a falsy value is equivalent to 'silent'
* `logging`: passing an object with functions for its debug, info, warn, error, and log properties will cause dbsync to
use the passed object for logging

#### Using a Migrator instance

A Migrator instance exposes 4 methods and 1 property of interest:
* `migrator.executionContext` is an object which may be inspected at any point during or after execution to get
information about the execution of the migration set.  (This object should never be modified or replaced while a
migration set is running.)
* `migrator.scanForFiles()` returns a promise of an array of strings representing files (relative to the `path` option)
which will be considered for migration, sorted in the order they will be considered according to the `order` option.
Files representing migrations which have already successfully executed will *not* be filtered from this list.
* `migrator.shouldMigrationRun(migrationId)` returns a promise of a boolean representing whether the migration needs to
run based on the migrator's options (so this function will always yield `true` when `blindly: true` is set).  The
`migrationId` for a file-based migration is the file's name, including path relative to the `path` option (as returned
by `scanForFiles()`).
* `migrator.doAllMigrationsIfNeeded()` is what is used to execute migrations based on a command line invocation.  If
`migrator.executionContext.files` is falsy, it will be set with the value returned by `migrator.scanForFiles()`, then
`migrator.executionContext.files` will be used as its list of migration files.  This means it is possible to set a
custom list of files (or a custom ordering of files) by setting `migrator.executionContext.files` before calling
`migrator.doAllMigrationsIfNeeded()`.  This method returns a promise which resolves to `migrator.executionContext` when
all the migrations in the list have been skipped (based on the result of `migrator.shouldMigrationRun(migrationId)`)
or have succeeded, or when a single migration fails.
* `migrator.doSingleMigrationIfNeeded(migrationId, [migrationSource])` is similar to
`migrator.doAllMigrationsIfNeeded()`, but only performs a single migration (or skips it, based on
`migrator.shouldMigrationRun(migrationId)`), and has a number of advanced behaviors available based on
`migrationSource`:
  * if `migrationSource` is `undefined` or `null`, then `migrationId` is treated as a filename; otherwise, it
`migrationId` is a user-defined string id which will identify this migration.
  * if `migrationSource` is a string, the string will be used as the content of the migration.
  * if `migrationsSource` is an instance of `stream.Readable`, the data from the stream will be used as the content of
the migration.  Note that the stream must return strings, not buffers.  (If you have a stream returning buffers, you
can make it return strings by calling `myStream.setEncoding(encoding)`.)
  * if `migrationSource` is a promise (or then-able) which resolves to a string or a readable stream, the resolved
value will be used as described above.
  * if `migrationSource` is a function, the function will be called and its return value (which must be a string,
readable stream, or promise to one of those) will be used as described above.  Note that the function will
only be called if `migrator.shouldMigrationRun(migrationId)` resolved to `true` for `migrationId`; this makes it useful
for migrations that require some effort/time/resources to set up, such as creating a stream that downloads a file from
a server.  By putting such setup in a function and passing that as the `migrationSource`, the download will never be
initiated unless dbsync intends to execute the migration.

Multiple Migrator instances may be created and used in parallel.  Since migrating a database is conceptually a serial
operation, this should (probably) not be used to perform parallel migrations on the same db, but only to perform
migrations on multiple dbs in parallel.

## Contributing

Contributions to this project are welcome; please create an issue ticket for bugs or feature requests, and submit a PR
if you have made improvements.  Feature requests submitted without a quality PR may not be implemented quickly.
