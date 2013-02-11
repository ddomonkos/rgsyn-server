#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if ! /etc/init.d/redis status > /dev/null 2>&1; then
  echo 'SCRIPT: Need to start Redis database'
  sudo /etc/init.d/redis start
fi

if god status > /dev/null 2>&1; then
  echo 'SCRIPT: Terminating God...'
  god terminate
fi

echo 'SCRIPT: (Re)moving old logs...'
rm -r $DIR/old_log
mv $DIR/log $DIR/old_log
mkdir -p $DIR/log/workers

echo 'SCRIPT: Removing files in repositories...'
rm -r $DIR/public/gem/*
mkdir -p $DIR/public/gem/gems
rm -r $DIR/public/yum/*

echo 'SCRIPT: Flushing Redis database...'
redis-cli flushall

echo 'SCRIPT: Starting God...'
god -c $DIR/rgsyn.god

echo "SCRIPT: All done!"
