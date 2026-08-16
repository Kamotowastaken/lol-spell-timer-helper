@echo off
rem Compiles the helper from source. Requires .NET Framework 4.x csc.
"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /r:System.Management.dll /out:"C:\League spell timing helper\spell_timer_helper.exe" "C:\League spell timing helper\src\spell_timer_helper.cs"
if %errorlevel%==0 (echo Build OK) else (echo Build FAILED)