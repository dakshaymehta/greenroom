#!/bin/bash
#
# Greenroom Worker Setup
#
# Deploys the Cloudflare Worker and sets API key secrets.
# Run from the repo root: ./scripts/setup.sh

set -e

WORKER_DIR="worker"

echo ""
echo "=== Greenroom Worker Setup ==="
echo ""

# Check prerequisites
if ! command -v node &> /dev/null; then
    echo "Error: Node.js is required. Install it from https://nodejs.org"
    exit 1
fi

if ! command -v npx &> /dev/null; then
    echo "Error: npx is required. It ships with Node.js 18+."
    exit 1
fi

# Navigate to worker directory
if [ ! -d "$WORKER_DIR" ]; then
    echo "Error: worker/ directory not found. Run this script from the repo root."
    exit 1
fi

cd "$WORKER_DIR"

# Install dependencies
echo "Installing dependencies..."
npm install
echo ""

# Log in to Cloudflare
echo "Logging in to Cloudflare..."
echo "(This will open your browser if you're not already authenticated.)"
echo ""
npx wrangler login
echo ""

# Set secrets
echo "=== Setting API Key Secrets ==="
echo ""
echo "Each secret will be stored securely in Cloudflare. Wrangler will prompt"
echo "you to paste the key — it won't be echoed to the terminal."
echo ""

echo "--- Anthropic API Key (required) ---"
echo "Get yours at: https://console.anthropic.com/"
npx wrangler secret put ANTHROPIC_API_KEY
echo ""

echo "--- AssemblyAI API Key (required) ---"
echo "Get yours at: https://www.assemblyai.com/"
npx wrangler secret put ASSEMBLYAI_API_KEY
echo ""

echo "--- Exa API Key (optional — enables Gary's web search) ---"
read -p "Set Exa API key? (y/N): " SET_EXA
if [[ "$SET_EXA" =~ ^[Yy]$ ]]; then
    echo "Get yours at: https://exa.ai/"
    npx wrangler secret put EXA_API_KEY
fi
echo ""

# Deploy
echo "=== Deploying Worker ==="
echo ""
npm run deploy
echo ""

echo "=== Done ==="
echo ""
echo "Copy the Worker URL printed above and paste it into Greenroom's Settings."
echo ""
