#!/usr/bin/env sh

[ $# -gt 0 ] || echo "usage: ./update_tests.sh [lox files]" && exit 1
odin build . || exit 1
for f in $*; do ./olox $f 1> ${f/.lox/.out} 2> ${f/.lox/.err}; done
