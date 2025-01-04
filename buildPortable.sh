#!/bin/bash
##
## buildPortable.sh
## Builds a portable liteXL with all settings and plugins
## contained in one folder that you can copy and move anywhere
## regardless of other instances installed on the same system.
##
## Usage: ./buildPortable.sh [<anything>]
## Without any argument a minimal selection of plugins are added.
##
## Giving any argument the full set of plugins from a compatible
## branch of SwissalpS' fork are downloaded and some activated.
## You can add symlinks in the user/plugins folder pointing at
## more plugins in the downloaded folder to install them.
## (Or copy or move them if you prefer, updates are mostly easier
## using the symlink method.)
##
## The resulting portable build can be found in the build folder.
## For exact names refer to the variable settings below.
## e.g. build211/liteXLportable2_1_1
##
## Note: this script is written for linux, your milage may vary on
## OS X and certainly on that other platform whose name ends in 'ws'.
## For those you may want to use the main build script directly:
## scripts/build.sh.
##
## Note to reviewers: we get away without using quotes for many path actions
## in this script because all our file and directory names comply with standards
## that let us skip that otherwise important detail.
##
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Lite XL."; exit 1
fi

# build directory
bDir="build211";
# final directory (is in build dir and is the actual product we are making here)
fDir="liteXLportable2_1_1";
# name of lite executable (SwissalpS has an aversion for dashes/hyphens in names.)
fExe="liteXL";
# name of the plugins directory when cloning repository
pluginsDir="pluginsSwissalpSv3_211";
# the branch to clone from
pluginsBranch="SwissalpSpluginVer3liteXLver2_1_1";
# URI to clone plugins from
pluginsRepo="https://github.com/SwissalpS/liteXLplugins.git";

rm -fr $bDir;
./scripts/build.sh -P -r -b $bDir\
  && echo "+++++++++++++++++++++++++++++++++++++++"\
  && echo "Apply SwissalpS' flavour"\
  && echo "+++++++++++++++++++++++++++++++++++++++"\
  && echo "Changing names"\
  && mv $bDir/lite-xl $bDir/$fDir\
  && mv $bDir/$fDir/lite-xl $bDir/$fDir/$fExe\
  && echo "Making user directories"\
  && mkdir -p $bDir/$fDir/user/libraries\
  && mkdir $bDir/$fDir/user/colors\
  && mkdir $bDir/$fDir/user/plugins\
  && echo "Making copy of libraries"\
  && cp -r --preserve=mode,timestamps user/libraries/*\
    $bDir/$fDir/user/libraries\
  && echo "Making base user config files"\
  && cp --preserve=mode,timestamps user/*\.lua $bDir/$fDir/user/\
  && echo "Adding colors"\
  && cp --preserve=mode,timestamps user/colors/*\.lua\
    $bDir/$fDir/user/colors/;

if [[ "" != "$1" ]]; then
  # plugins the simple installer installs but aren't in the plugins branch
  # note: pre and post space is essential
  notInRepo=" lintplus lsp lsp_lua.lua lsp_snippets.lua snippets.lua testdirwatch.lua ";
  # additional plugins from the selected branch
  additional="autoinsert bracketmatch colorpicker copyfilelocation force_syntax gitstatus indentguide keymap_export lfautoinsert markers open_ext scalestatus selectionhighlight spellcheck sticky_scroll titleize todotreeview togglesnakecamel";
  echo "Fetching plugins from $pluginsBranch of $pluginsRepo";
  cd $bDir/$fDir/user;
  git clone -b $pluginsBranch --single-branch $pluginsRepo $pluginsDir;
  cd plugins;
  echo "Setting up seletcion of plugins";
  # install all that would be activated without fetching from repository
  # in case directory doesn't exist (or is empty) for some reason
  shopt -s nullglob;
  for f in ../../../../user/plugins/*; do
    n=`basename $f`;
    echo "++$n";
    if [[ $notInRepo =~ " $n " ]]; then
      # copy from core repository
      #echo "$n";
      cp -r --preserve=mode,timestamps ../../../../user/plugins/$n ./;
    else
      # symlink to plugins repository
      ln -s ../$pluginsDir/plugins/$n;
    fi;
  done;
  # install all the languages from fetched repository
  echo "Installing additional syntax highlighters";
  for f in ../$pluginsDir/plugins/language_*; do
    n=`basename $f`;
    # make sure it hasn't already been added in previous step
    if [ ! -e $n ]; then
      echo "++$n";
      ln -s ../$pluginsDir/plugins/$n;
    fi;
  done;
  shopt -u nullglob;
  # install some of the fetched plugins
  echo "Installing additional plugins from repository";
  for f in $additional; do
    n=$f.lua;
    echo "++$n";
    ln -s ../$pluginsDir/plugins/$n;
  done;
  cd ../../../../;
else
  echo "Copy base plugins and syntax highlighters";
  cp -r --preserve=mode,timestamps user/plugins/* $bDir/$fDir/user/plugins;
fi;
echo "Done, have a nice day :D";
echo "Move $bDir/$fDir to wherever you like and enjoy.";

