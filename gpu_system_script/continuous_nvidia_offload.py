#!/usr/bin/env python3
import tensorflow as tf
import time
import logging
import psutil

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Function to check CPU usage
def get_cpu_usage():
    return psutil.cpu_percent(interval=1)

# Function to perform a more complex TensorFlow operation on GPU
def perform_complex_operation():
    # Create a simple neural network
    model = tf.keras.Sequential([
        tf.keras.layers.Dense(128, activation='relu', input_shape=(784,)),
        tf.keras.layers.Dense(10, activation='softmax')
    ])

    # Compile the model
    model.compile(optimizer='adam', loss='sparse_categorical_crossentropy', metrics=['accuracy'])

    # Generate some random data
    x_train = tf.random.normal([60000, 784])
    y_train = tf.random.uniform([60000], minval=0, maxval=10, dtype=tf.int64)

    # Train the model
    model.fit(x_train, y_train, epochs=1)
    logger.info('Completed a complex TensorFlow operation on GPU.')

# Function to monitor and offload tasks to GPU
def monitor_and_offload():
    # Check for GPU availability
    gpus = tf.config.experimental.list_physical_devices('GPU')
    if gpus:
        try:
            # Set memory growth for GPUs
            for gpu in gpus:
                tf.config.experimental.set_memory_growth(gpu, True)
            logical_gpus = tf.config.experimental.list_logical_devices('GPU')
            logger.info(f'{len(gpus)} Physical GPUs, {len(logical_gpus)} Logical GPUs configured for TensorFlow.')
        except RuntimeError as e:
            logger.error(e)
    else:
        logger.warning('No GPU found. TensorFlow will use CPU.')

    while True:
        cpu_usage = get_cpu_usage()
        logger.info(f'Current CPU usage: {cpu_usage}%')
        if cpu_usage > 20:  # Adjust the threshold as needed
            perform_complex_operation()
        time.sleep(5)

if __name__ == "__main__":
    monitor_and_offload()

