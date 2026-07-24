# Gera demo.gif -- ghost-text autocomplete ao vivo (Gemini real)
# Rodar: vhs demo.tape (a partir da raiz deste repo)

Output demo.gif

Set Shell "zsh"
Set FontSize 20
Set Width 1000
Set Height 600
Set Theme "Dracula"

Hide
Type "vim -N -u ~/.vimrc /tmp/vhs_demo.py"
Enter
Sleep 1500ms
Show

Type "idef quicksort("
Sleep 5000ms
Tab
Sleep 3000ms
Escape
Sleep 500ms
Type ":q!"
Enter
Sleep 500ms
