@echo off
chcp 65001 >nul
title 软件库管理后台
echo 正在启动软件库管理后台...
echo.
echo   浏览器打开: http://localhost:8080/admin?key=admin123
echo   其他机器访问: 把 localhost 换成服务器IP（需管理员运行本bat并对IT开放8080端口）
echo   关闭本窗口即停止服务
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Admin-Server.ps1" %*
pause
