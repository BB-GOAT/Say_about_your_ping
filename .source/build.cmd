@echo off
rem 编译 pingspy_x64.dll 到本目录（占用时部署：关服后复制到模组根覆盖）；正式版不带 PINGSPY_LOG，开发诊断版加回 /DPINGSPY_LOG
call "D:\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d "%~dp0"
cl /nologo /utf-8 /W4 /O2 /MT /LD pingspy.c /Fe:pingspy_x64.dll
if errorlevel 1 (echo BUILD FAILED & exit /b 1)
del /q pingspy.obj pingspy_x64.lib pingspy_x64.exp >nul 2>&1
echo BUILD OK
