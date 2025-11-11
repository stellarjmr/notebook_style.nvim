#!/usr/bin/env python3
# %%
# Cell 1: Import libraries
import numpy as np
import matplotlib.pyplot as plt

print("Libraries imported successfully")

# %%
# Cell 2: Generate data
x = np.linspace(0, 2 * np.pi, 100)
y = np.sin(x)

print(f"Generated {len(x)} data points")

# %%
# Cell 3: Create visualization
plt.figure(figsize=(10, 6))
plt.plot(x, y, label='sin(x)')
plt.xlabel('x')
plt.ylabel('y')
plt.title('Sine Wave')
plt.legend()
plt.grid(True)

# %%
# Cell 4: Analysis
mean_value = np.mean(y)
std_value = np.std(y)

print(f"Mean: {mean_value:.4f}")
print(f"Std Dev: {std_value:.4f}")

# %%
# Cell 5: Define helper functions
def calculate_statistics(data):
    """Calculate basic statistics for a dataset."""
    return {
        'mean': np.mean(data),
        'median': np.median(data),
        'std': np.std(data),
        'min': np.min(data),
        'max': np.max(data),
    }

stats = calculate_statistics(y)
for key, value in stats.items():
    print(f"{key}: {value:.4f}")

