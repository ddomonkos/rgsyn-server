# Rgsyn

Rgsyn is a client-server application that is capable of converting RubyGems
libraries from gem packages to RPM and vice versa.

This web service was created within *Tool for RubyGems -- RPM synchronization* thesis. For more information see the [thesis](http://is.muni.cz/th/373796/fi_b/thesis.pdf) itself.

# Rgsyn-server

The server part of Rgsyn does all the hard work involved during conversion.
It provides RESTful API, through which it receives packages that should be
converted, as well as other commands and queries user might be interested in.

Rgsyn-server also provides repositories with all the packages that were
received or created, along with metadata about the repositories required by
the two standard clients - RubyGems client (or simply `gem`, as known from
command line) and Yum - for gem and RPM packages respectively.

## DEPENDENCIES:

 * Redis - database (`yum install redis`)
 * Mock - RPM building tool (`yum install mock`)
 * Ruby-devel - necessary, in order to build libraries listed in the Gemfile
 (`yum install ruby-devel`)

## SERVER CONFIGURATION:

Before the server can be deployed, it must be configured. The configuration file
is located in `config/rgsyn-server.yml`. Instructions are included in the file
in the form of comments.

## SERVER DEPLOYMENT:

 * make sure that the user running the Rgsyn server belongs to group 'mock'
 * start up Redis server (`sudo /etc/init.d/redis start` should do the trick)
 * start up Rgsyn server using God (`god -c rgsyn.god`)

## DEVELOPMENT:

To make server (re)starting easier and faster, developers can make use of the
scratch_start.sh bash script that automates the following steps:

 * start Redis database server (if not running yet)
 * terminate previous instance of Rgsyn server - kills the server as well as
 its workers
 * clean up logs, public directories and destroy all data in Redis - so that
 the newly started server will be completely clean
 * start Rgsyn server

## HARDWARE REQUIREMENTS:

Due to the fact that building RPM packages is very resource-intensive, Rgsyn
server has high hardware requirements -- or in other words, individual
conversions may take a long time to finish.

Especially long is usually the first gem to RPM conversion on a clean system,
as the used Mock utility needs to download and cache necessary packages.

## COMPATIBILITY:

Even though there are other Linux distributions using RPM, Rgsyn was tested
only on Fedora.
