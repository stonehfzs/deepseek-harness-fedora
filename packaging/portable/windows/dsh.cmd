@echo off
rem dsh — portable launcher for the DeepSeek Harness runtime (Windows).
rem
rem Mirrors the POSIX launcher (packaging/rpm/dsh-wrapper.sh): default DSH_HOME,
rem apply the packaged overlay on profile boots, forward every argument, and
rem return the runtime's exit status.
rem
rem Set DSH_PACKAGED_PATCH=0 to skip the overlay.
rem
rem The `web` alias is rewritten to `--profile web`, because commander rejects
rem parent flags (--patch) in front of the `web` subcommand.

setlocal enabledelayedexpansion
set "HERE=%~dp0"
if not defined DSH_HOME set "DSH_HOME=%USERPROFILE%\.dsh"
set "RUNTIME=%HERE%dsh-runtime.exe"
set "OVERLAY=%HERE%patches\00-packaged-workarounds.yml"

if not exist "%RUNTIME%" (
    echo dsh: runtime executable not found at "%RUNTIME%" 1>&2
    exit /b 127
)

rem Collect everything after the first token, re-quoting as we go.
set "FIRST=%~1"
set "REST="
shift
:collect
if "%~1"=="" goto collected
set REST=!REST! "%~1"
shift
goto collect
:collected

if "%DSH_PACKAGED_PATCH%"=="0" goto plain
if "%FIRST%"==""             goto boot
if /i "%FIRST%"=="plugin"    goto plain
if /i "%FIRST%"=="--version" goto plain
if /i "%FIRST%"=="-V"        goto plain
if /i "%FIRST%"=="--help"    goto plain
if /i "%FIRST%"=="-h"        goto plain
if /i "%FIRST%"=="web"       goto web
goto boot

:web
"%RUNTIME%" --profile web --patch "%OVERLAY%" !REST!
exit /b %ERRORLEVEL%

:boot
"%RUNTIME%" --patch "%OVERLAY%" %*
exit /b %ERRORLEVEL%

:plain
"%RUNTIME%" %*
exit /b %ERRORLEVEL%
