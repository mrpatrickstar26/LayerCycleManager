@echo off
rem last_session.cmd - runs last_session.cjs when node is not in PATH.
rem Node lives inside the DSH runtime: ~/.dsh/dsh-runtimes/*/dependencies/node/bin
rem Override the interpreter with the DSH_NODE environment variable.
setlocal
set "SCRIPT=%~dp0last_session.cjs"
if not exist "%SCRIPT%" (
  echo last_session.cjs not found next to this wrapper 1>&2
  exit /b 1
)
if not defined DSH_NODE call :find_node
if not defined DSH_NODE (
  echo Node.js not found. Set DSH_NODE to node.exe 1>&2
  exit /b 1
)
"%DSH_NODE%" "%SCRIPT%" %*
exit /b %ERRORLEVEL%

:find_node
for /d %%D in ("%USERPROFILE%\.dsh\dsh-runtimes\*") do (
  if exist "%%~fD\dependencies\node\bin\node.exe" (
    set "DSH_NODE=%%~fD\dependencies\node\bin\node.exe"
    exit /b 0
  )
)
for %%N in (node.exe) do if not "%%~$PATH:N"=="" set "DSH_NODE=%%~$PATH:N"
exit /b 0