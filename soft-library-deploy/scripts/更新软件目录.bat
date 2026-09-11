@echo off
chcp 65001 >nul
title 更新软件目录
echo 正在扫描 soft 目录并重新生成软件库页面数据...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Catalog.ps1" %*
echo.
pause
