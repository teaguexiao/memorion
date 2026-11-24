import logging
from datetime import datetime

# Create a custom logger
logger = logging.getLogger('omi')
logger.setLevel(logging.INFO)

# Create handlers
console_handler = logging.StreamHandler()
file_handler = logging.FileHandler('omi/backend/log.txt')

# Create formatters and add it to handlers
log_format = logging.Formatter('%(asctime)s - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
console_handler.setFormatter(log_format)
file_handler.setFormatter(log_format)

# Add handlers to the logger
logger.addHandler(console_handler)
logger.addHandler(file_handler)

def log_info(message):
    """Log an info message with timestamp"""
    logger.info(message)

def log_error(message):
    """Log an error message with timestamp"""
    logger.error(message)

def log_warning(message):
    """Log a warning message with timestamp"""
    logger.warning(message)

def log_debug(message):
    """Log a debug message with timestamp"""
    logger.debug(message) 