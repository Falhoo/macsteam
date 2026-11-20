#!/bin/bash
# Double-click this file in Finder to build the app.
cd "$(dirname "$0")"
./build.sh
status=$?
echo
if [ $status -eq 0 ]; then
    echo "Finished. Opening the folder with your app..."
    open dist
else
    echo "The build stopped (see the message above). Copy it and send it to Claude."
fi
echo
read -n 1 -s -r -p "Press any key to close this window."
