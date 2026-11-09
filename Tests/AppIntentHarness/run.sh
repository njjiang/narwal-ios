#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
task_build=$(mktemp -d /private/tmp/freo-appintent-check.XXXXXX)
trap 'rm -rf "$task_build"' EXIT HUP INT TERM
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-/private/tmp/freo-swift-module-cache}
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$task_root/FreoControl/Core/Models.swift" \
  "$task_root/FreoControl/Core/MapPixel.swift" \
  "$task_root/FreoControl/Core/CleaningOptions.swift" \
  "$task_root/FreoControl/Core/SiriRoomReference.swift" \
  "$task_root/FreoControl/App/FreoIntents.swift" \
  "$task_root/Tests/AppIntentHarness/Main.swift" -o "$task_build/check"
"$task_build/check"
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -lz \
  "$task_root/FreoControl/Core/Models.swift" \
  "$task_root/FreoControl/Core/SiriRoomReference.swift" \
  "$task_root/FreoControl/Core/RoomSelection.swift" \
  "$task_root/FreoControl/Core/FloorplanCache.swift" \
  "$task_root/FreoControl/Core/CleaningOptions.swift" \
  "$task_root/FreoControl/Core/MapPixel.swift" \
  "$task_root/FreoControl/Core/ProtocolCodec.swift" \
  "$task_root/FreoControl/Core/RoomDoorReadback.swift" \
  "$task_root/FreoControl/Core/RoomPartitionPlanner.swift" \
  "$task_root/FreoControl/Core/MapEditCoordinates.swift" \
  "$task_root/FreoControl/Core/RoomPartitionTransaction.swift" \
  "$task_root/FreoControl/Core/MapEditTransaction.swift" \
  "$task_root/FreoControl/Core/RoomRenameTransaction.swift" \
  "$task_root/FreoControl/Core/RoomMergeTransaction.swift" \
  "$task_root/FreoControl/Core/MapSnapshotStore.swift" \
  "$task_root/FreoControl/Core/RobotTrajectory.swift" \
  "$task_root/FreoControl/Core/ActiveCleaningTask.swift" \
  "$task_root/FreoControl/Core/LiveTelemetry.swift" \
  "$task_root/FreoControl/Core/CleaningHistoryStore.swift" \
  "$task_root/FreoControl/Core/NarwalHistoryCodec.swift" \
  "$task_root/FreoControl/Core/RobotSchedule.swift" \
  "$task_root/FreoControl/Core/RobotScheduleContext.swift" \
  "$task_root/FreoControl/Core/NarwalScheduleCodec.swift" \
  "$task_root/FreoControl/App/FreoStore.swift" \
  "$task_root/FreoControl/App/FreoStore+Schedules.swift" \
  "$task_root/FreoControl/App/FreoIntents.swift" \
  "$task_root/Tests/AppIntentHarness/LiveStoreHarness.swift" \
  "$task_root/Tests/AppIntentHarness/ScheduleStoreHarness.swift" \
  "$task_root/Tests/AppIntentHarness/SessionStoreHarness.swift" \
  "$task_root/Tests/AppIntentHarness/CurrentTaskStoreHarness.swift" \
  "$task_root/Tests/AppIntentHarness/RoomNamesStoreHarness.swift" \
  "$task_root/Tests/AppIntentHarness/RoomMergeStoreHarness.swift" \
  "$task_root/Tests/AppIntentHarness/StoreMain.swift" -o "$task_build/store-check"
"$task_build/store-check"
