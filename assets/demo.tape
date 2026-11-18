# Records the README demo against the real `claude` CLI and your own nvim
# config (harner installed, bash tool enabled). Run assets/demo.sh from the
# repo root: it runs this tape, then cuts Claude's thinking pauses out of
# the raw recording and writes assets/demo.mp4 and assets/demo.gif.

Output assets/demo-raw.mp4
Set Shell bash
Set FontFamily "Lilex Nerd Font Mono"
# 2x of a 1200x660 terminal, so the video stays sharp on HiDPI screens
Set FontSize 30
Set Width 2400
Set Height 1320
Set Padding 0
Set Theme "nord"
Set CursorBlink false
Set TypingSpeed 55ms
Set WaitTimeout 180s

# the demo project is copied out of the repo so this CLAUDE.md stays out of
# the session; demo-init.lua holds the config overrides and the key chip
Hide
Type "rm -rf /tmp/harner-demo && cp -r assets/demo /tmp/harner-demo && cd /tmp/harner-demo && clear" Enter
Type `nvim cart.py -c "luafile $OLDPWD/assets/demo-init.lua"` Enter
Sleep 4s
Show
Sleep 1s

# select the broken method and ask about it
Type@120ms "23G"
Sleep 700ms
Type "V"
Sleep 700ms
Type@250ms "jj"
Sleep 900ms
Space
Type@150ms "hh"
Sleep 900ms
Type "test_discount fails. fix this and run the tests"
Sleep 600ms
Enter
Sleep 2s
# auto mode: the classifier lets the test run pass without a confirm
Wait+Screen /\$\d+\.\d+ last/
Sleep 3s

# a follow-up in the same session, answered with a table
Space
Type@150ms "hh"
Sleep 900ms
Type "which methods have no test yet? short table"
Sleep 600ms
Enter
Sleep 2s
Wait+Screen /\$\d+\.\d+ last/
Sleep 4s

Hide
Type ":qa!" Enter
