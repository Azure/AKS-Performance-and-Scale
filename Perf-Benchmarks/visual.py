import pandas as pd
import os
import matplotlib.pyplot as plt

PATH_TO_FILE = '' # Replace as necessary
FILE_NAME = "output.json"

benchmark_file = os.path.join(PATH_TO_FILE, FILE_NAME)

if os.path.isfile(benchmark_file): # Make sure file exists
    benchmark_df = pd.read_json(benchmark_file)
    
    # Removes "seconds" suffix and converts value to numeric
    benchmark_df_cleaned = benchmark_df.apply(lambda x: pd.to_numeric((x.str.split('seconds').str[0]).str.strip())) 
    
    # Aggregated Stats for each metric 
    display(benchmark_df_cleaned.describe()) 
    
    # Plot each metric into a separate graph
    for col in benchmark_df_cleaned.columns:
        plt.xticks(benchmark_df_cleaned.index)
        plt.scatter(benchmark_df_cleaned.index, benchmark_df_cleaned[col])
        plt.title(col)
        plt.xlabel('Run #')
        plt.ylabel('Time (in seconds)')
        plt.show()