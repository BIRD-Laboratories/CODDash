#!/bin/bash

# Check if virtual environment exists
if [ ! -d "vmvenv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv vmvenv
fi

# Activate virtual environment
source vmvenv/bin/activate

# Install requirements if requirements.txt exists
if [ -f "requirements.txt" ]; then
    echo "Installing requirements..."
    pip install -r requirements.txt
fi

echo "Virtual environment vmvenv is activated"
