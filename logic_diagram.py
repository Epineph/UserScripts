#!/usr/bin/env python
import matplotlib.pyplot as plt
import networkx as nx

# Create a directed graph
G = nx.DiGraph()

# Define nodes with multi-line labels
nodes = {
    "A_or_B": "Assumption:\nPlace Learning (A)\nOR\nResponse Learning (B)\nis True",
    "Obs_A": "Observed A\n(Place Learning)",
    "Obs_B": "Observed B\n(Response Learning)",
    "Not_Obs_A": "Did NOT Observe A",
    "Not_Obs_B": "Did NOT Observe B",
    "Conc_A": "Conclusion:\nPlace Learning (A)\nis True",
    "Conc_B": "Conclusion:\nResponse Learning (B)\nis True",
    "Circular": "Circular Reasoning:\nAll Outcomes\nConfirm the Model"
}

# Add nodes to the graph
G.add_nodes_from(nodes.keys())

# Define edges (logical flow)
edges = [
    ("A_or_B", "Obs_A"),
    ("A_or_B", "Obs_B"),
    ("A_or_B", "Not_Obs_A"),
    ("A_or_B", "Not_Obs_B"),
    ("Obs_A", "Conc_A"),
    ("Obs_B", "Conc_B"),
    ("Not_Obs_A", "Conc_B"),
    ("Not_Obs_B", "Conc_A"),
    ("Conc_A", "Circular"),
    ("Conc_B", "Circular"),
]
G.add_edges_from(edges)

# Positions carefully laid out for readability
pos = {
    "A_or_B":      (0,  3.0),
    "Obs_A":       (-2.5,  1.8),
    "Obs_B":       ( 2.5,  1.8),
    "Not_Obs_A":   (-1.5,  0.6),
    "Not_Obs_B":   ( 1.5,  0.6),
    "Conc_A":      (-2.5, -0.6),
    "Conc_B":      ( 2.5, -0.6),
    "Circular":    ( 0,  -2.0),
}

# Define custom colors for each node
node_colors = {
    "A_or_B":   "#ADD8E6",  # lightblue
    "Obs_A":    "#90EE90",  # lightgreen
    "Obs_B":    "#90EE90",  # lightgreen
    "Not_Obs_A": "#FFFACD", # lightyellow
    "Not_Obs_B": "#FFFACD", # lightyellow
    "Conc_A":   "#F08080",  # lightcoral
    "Conc_B":   "#F08080",  # lightcoral
    "Circular": "#FF6961",  # red (slightly softer)
}

# Convert node_colors dict to a list matching G.nodes() order
colors = [node_colors[node] for node in G.nodes()]

# Plot settings
plt.figure(figsize=(12, 7))  # Wider figure to accommodate text
nx.draw_networkx(
    G, pos,
    labels=nodes,          # use our custom labels
    node_color=colors,     # color array
    edge_color="black",
    node_size=7000,        # larger nodes to fit multiline text
    font_size=9,           # slightly smaller font for multiline
    font_weight="bold",
    arrows=True
)

plt.title("Logical Flaw in Place vs. Response Learning Paradigm", fontsize=14, fontweight="bold")
plt.axis("off")
plt.tight_layout()
plt.show()

