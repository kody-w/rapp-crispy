Release assembly puts the pinned whisper-cli at bin/whisper-cli in this folder,
along with its required libraries and licenses. XcodeGen preserves this as a
folder reference so Contents/Resources/runtime/bin does not become flattened.

This declaration is not a placeholder executable. Without the assembled runtime,
the app displays a missing-runtime error while local capture and history remain
available. No executable is downloaded by the app.
