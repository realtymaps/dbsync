var path   = require('path');
var fs     = require('fs');
var coffee = require('coffee-script');
var src    = path.join(path.dirname(fs.realpathSync(__filename)), '../src');

coffee.register();
module.exports = require(src + '/migrator');
