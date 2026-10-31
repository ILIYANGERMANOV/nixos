# Fixture for the sudo ban in `shell-just`, never run. The comment-only cases
# sit in shebang recipes, since a linewise recipe drops its comments earlier.

plain x:
    sudo echo {{ x }}

after-comment x:
    #!/usr/bin/env bash
    # note \
    sudo echo {{ x }}

commented-out x:
    #!/usr/bin/env bash
    # sudo echo {{ x }}
