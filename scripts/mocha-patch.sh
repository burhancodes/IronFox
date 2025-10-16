#!/bin/bash

set -e

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m"

PATCHES_YAML="scripts/patches.yaml"
MOCHA_PATCH="patches/mocha.patch"

if [ ! -f "$MOCHA_PATCH" ]; then
    echo -e "${RED}Error: mocha.patch file not found at $MOCHA_PATCH${NC}"
    exit 1
fi

# Add mocha.patch entry to patches.yaml
cat << 'EOF' >> "$PATCHES_YAML"

  - file: "mocha.patch"
    name: "Mocha colors for default dark mode"
    description: "Replace the default dark mode with Catppuccin Mocha color scheme."
    reason: "To provide a more visually appealing dark mode experience."
    effect: "Users get a more polished and modern dark mode appearance."
    category: "User Interface"
EOF

echo -e "${GREEN}Successfully added Mocha theme to patches.yaml!${NC}"
