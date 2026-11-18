cmake_minimum_required(VERSION 3.21)
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0 CACHE STRING "")
project(OberVaveAU VERSION 0.2.0 LANGUAGES C CXX OBJCXX Swift)
set(CMAKE_CXX_STANDARD 17)
if(CMAKE_OSX_ARCHITECTURES)
    set(EDITOR_ARCH "${CMAKE_OSX_ARCHITECTURES}")
else()
    set(EDITOR_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
endif()
if(EDITOR_ARCH MATCHES ";")
    message(FATAL_ERROR "Build one architecture at a time (x86_64 or arm64).")
endif()
add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:-target;${EDITOR_ARCH}-apple-macosx${CMAKE_OSX_DEPLOYMENT_TARGET}>")
add_link_options("$<$<LINK_LANGUAGE:Swift>:-target;${EDITOR_ARCH}-apple-macosx${CMAKE_OSX_DEPLOYMENT_TARGET}>")
set(AUDIOUNIT_SDK "" CACHE PATH "Apple AudioUnitSDK source directory")
if(NOT EXISTS "${AUDIOUNIT_SDK}/include/AudioUnitSDK/AUBase.h")
    include(FetchContent)
    FetchContent_Declare(apple_au_sdk
        GIT_REPOSITORY https://github.com/apple/AudioUnitSDK.git
        GIT_TAG 53a9a2008aae7fb1b0a9f093dd523b9b12f6c0d9)
    FetchContent_MakeAvailable(apple_au_sdk)
    set(AUDIOUNIT_SDK "${apple_au_sdk_SOURCE_DIR}")
endif()
file(GLOB SDK_SOURCES CONFIGURE_DEPENDS "${AUDIOUNIT_SDK}/src/AudioUnitSDK/*.cpp")
add_library(OberVaveEditor STATIC Editor.swift "../../ios/OberVave/ContentView.swift"
    "../../ios/OberVave/SynthParameter.swift")
target_compile_options(OberVaveEditor PRIVATE -DOBERVAVE_AU
    -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/UIBridge.h")
set_target_properties(OberVaveEditor PROPERTIES Swift_LANGUAGE_VERSION 5)
add_library(OberVave MODULE OberVaveAU.cpp CocoaView.mm ${SDK_SOURCES})
set_source_files_properties(CocoaView.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_include_directories(OberVave PRIVATE
    "${AUDIOUNIT_SDK}/include"
    "../../fw/obervave/firmware/gen")
target_compile_options(OberVave PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:-Wno-c99-designator>")
target_link_libraries(OberVave PRIVATE
    OberVaveEditor "-framework Cocoa" "-framework SwiftUI"
    "-framework AudioToolbox" "-framework AudioUnit" "-framework CoreFoundation")
set_target_properties(OberVave PROPERTIES
    BUNDLE TRUE BUNDLE_EXTENSION component
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    PREFIX "" SUFFIX "")
add_executable(check_obervave_au check.cpp)
target_include_directories(check_obervave_au PRIVATE "../../fw/obervave/firmware/gen")
target_compile_options(check_obervave_au PRIVATE -Wno-c99-designator)
target_link_libraries(check_obervave_au PRIVATE "-framework AudioToolbox" "-framework CoreFoundation")
enable_testing()
add_executable(check_musical_events "../Musical/check_events.cpp")
target_compile_options(check_musical_events PRIVATE -UNDEBUG)
add_test(NAME musical_events COMMAND check_musical_events)
add_executable(check_musical_arpeggiator "../Musical/check_arpeggiator.cpp")
target_compile_options(check_musical_arpeggiator PRIVATE -UNDEBUG -Wno-c99-designator)
target_compile_definitions(check_musical_arpeggiator PRIVATE OB1_ARP_REFERENCE)
target_include_directories(check_musical_arpeggiator PRIVATE "../../fw/obervave/firmware/gen")
add_test(NAME musical_arpeggiator COMMAND check_musical_arpeggiator)
add_test(NAME native_au COMMAND check_obervave_au "$<TARGET_BUNDLE_DIR:OberVave>")
add_executable(check_obervave_transport check_transport.cpp)
target_include_directories(check_obervave_transport PRIVATE "../../fw/obervave/firmware/gen")
target_compile_options(check_obervave_transport PRIVATE -UNDEBUG -Wno-c99-designator)
add_test(NAME ipad_transport COMMAND check_obervave_transport)
add_executable(check_obervave_rack check_rack.cpp)
target_include_directories(check_obervave_rack PRIVATE "../../fw/obervave/firmware/gen")
target_compile_options(check_obervave_rack PRIVATE -UNDEBUG -Wno-c99-designator)
add_test(NAME ipad_rack COMMAND check_obervave_rack)
add_executable(check_obervave_scenes check_scenes.swift
    "../../ios/OberVave/KeyboardLockState.swift"
    "../../ios/OberVave/SceneState.swift" "../../ios/OberVave/SynthParameter.swift"
    "../../ios/OberVave/SynthRack.cpp")
target_include_directories(check_obervave_scenes PRIVATE "../../fw/obervave/firmware/gen")
target_compile_options(check_obervave_scenes PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-import-objc-header;${CMAKE_CURRENT_SOURCE_DIR}/../../ios/OberVave/OberVave-Bridging-Header.h>"
    "$<$<COMPILE_LANGUAGE:CXX>:-Wno-c99-designator>")
add_test(NAME ipad_scene_files COMMAND check_obervave_scenes)
add_executable(check_obervave_editor check_editor.mm)
target_compile_options(check_obervave_editor PRIVATE -fobjc-arc)
target_link_libraries(check_obervave_editor PRIVATE "-framework Cocoa" "-framework AudioToolbox")
add_test(NAME editor COMMAND check_obervave_editor "$<TARGET_BUNDLE_DIR:OberVave>"
    "${CMAKE_CURRENT_BINARY_DIR}")
