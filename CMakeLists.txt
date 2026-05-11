cmake_minimum_required(VERSION 3.20)
project(SelectToClipboard LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(SelectToClipboard SHARED
    src/SelectToClipboard.mm
)

target_link_libraries(SelectToClipboard PRIVATE
    "-framework Cocoa"
)

target_include_directories(SelectToClipboard PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
)

set_target_properties(SelectToClipboard PROPERTIES
    PREFIX ""
    SUFFIX ".dylib"
    OUTPUT_NAME "SelectToClipboard"
)

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.nextpad++/plugins/SelectToClipboard")
install(TARGETS SelectToClipboard DESTINATION "${PLUGIN_INSTALL_DIR}")
