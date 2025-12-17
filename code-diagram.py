#!/usr/bin/env python3

from graphviz import Digraph

g = Digraph("place_response_circularity", format="png")
g.attr(
    rankdir="TB",
    labelloc="t",
    fontsize="20",
    fontname="Helvetica",
    label="Why the Place vs. Response 'Direct-Opposition' Probe Can Become Circular",
)
g.attr("node", fontname="Helvetica", fontsize="12", style="filled", color="black")

g.node(
    "prem",
    "Hidden premises\n(rarely stated)\n\n"
    "1) Place XOR Response (exhaustive + exclusive)\n"
    "2) Probe choice ≈ Strategy (classification rule)",
    shape="ellipse",
    fillcolor="#b7d7e8",
)

g.node(
    "probe",
    "Forced-choice probe\n(start position changed)\n\n"
    "Only two bins:\nPlace-arm OR Response-arm",
    shape="box",
    fillcolor="#dfeaf3",
)

g.node("obsP", "Observed: chooses\nPLACE arm", shape="circle", fillcolor="#b6f2b6")
g.node("obsR", "Observed: chooses\nRESPONSE arm", shape="circle", fillcolor="#b6f2b6")

g.node(
    "conP", "Conclusion:\n'Place strategy'\n(P)", shape="circle", fillcolor="#f28c8c"
)
g.node(
    "conR", "Conclusion:\n'Response strategy'\n(R)", shape="circle", fillcolor="#f28c8c"
)

g.node(
    "circ",
    "Circularity:\nAll outcomes\n'confirm' the model\nbecause labels are\nread off the bins",
    shape="circle",
    fillcolor="#ff6b6b",
)

g.node(
    "alt",
    "Unmeasured contributors\n(can drive the same choice)\n\n"
    "• failure to express / inhibit competing action\n"
    "• motor/program selection limits\n"
    "• cue affordances / environment definition\n"
    "• probe novelty / conflict",
    shape="box",
    fillcolor="#e6e6e6",
)

g.node(
    "altP",
    "Alt. explanation for\nPLACE-arm choice:\n\n"
    "'Not response' (impairment)\n≠ 'Uses place'",
    shape="box",
    fillcolor="#fff3bf",
)
g.node(
    "altR",
    "Alt. explanation for\nRESPONSE-arm choice:\n\n"
    "'Not place' (impairment)\n≠ 'Uses response'",
    shape="box",
    fillcolor="#fff3bf",
)

with g.subgraph() as s:
    s.attr(rank="same")
    s.node("obsP")
    s.node("obsR")

with g.subgraph() as s:
    s.attr(rank="same")
    s.node("conP")
    s.node("conR")

with g.subgraph() as s:
    s.attr(rank="same")
    s.node("altP")
    s.node("altR")

g.edge("prem", "probe")
g.edge("probe", "obsP")
g.edge("probe", "obsR")
g.edge("obsP", "conP")
g.edge("obsR", "conR")
g.edge("conP", "circ")
g.edge("conR", "circ")

g.edge("alt", "obsP", style="dashed")
g.edge("alt", "obsR", style="dashed")

g.edge("obsP", "altP", style="dashed")
g.edge("obsR", "altR", style="dashed")
g.edge("altP", "conP", style="dashed", label="(invalid inference if assumed)")
g.edge("altR", "conR", style="dashed", label="(invalid inference if assumed)")

g.render("place_response_circularity_enhanced", cleanup=True)
