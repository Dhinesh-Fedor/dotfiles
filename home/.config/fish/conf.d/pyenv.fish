set -gx PYENV_ROOT $HOME/.pyenv
fish_add_path $PYENV_ROOT/bin

if command -q pyenv
    pyenv init - fish | source
end
