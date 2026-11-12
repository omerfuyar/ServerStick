# Status banner on local console logins only (tty1 autologin, serial console).
case "$(tty 2>/dev/null)" in
    /dev/tty[0-9]*|/dev/ttyS[0-9]*) /usr/local/bin/serverstick-status.lua ;;
esac
