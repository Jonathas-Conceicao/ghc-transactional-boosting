#! /bin/bash

SUB_MODULE_FILES=list_of_submodules
GHC_PATH=/home/jonathas/Workspace/ghc

# git config --file .gitmodules --get-regexp . | sed -e '/.url/d' | sed -e '/.ignore/d' | sed -e '/.branch/d' | sed -e 's/submodule.* //' > $SUB_MODULE_FILES

while read pathToFile; do
  # echo "moving $pathToFile to ${pathToFile}_tmp"
  # mv $pathToFile ${pathToFile}_tmp
  # git submodule deinit $pathToFile
  # git rm --cached $pathToFile
  # rm -r $pathToFile
  # mv ${pathToFile}_tmp $pathToFile
  cd ${pathToFile}/
  ./configure
done < $SUB_MODULE_FILES
