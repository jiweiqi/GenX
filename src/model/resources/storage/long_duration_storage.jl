"""
GenX: An Configurable Capacity Expansion Model
Copyright (C) 2021,  Massachusetts Institute of Technology
This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
A complete copy of the GNU General Public License v2 (GPLv2) is available
in LICENSE.txt.  Users uncompressing this from an archive may not have
received this license file.  If not, see <http://www.gnu.org/licenses/>.
"""

@doc raw"""
	long_duration_storage(EP::Model, inputs::Dict)

This function creates variables and constraints enabling modeling of long duration storage resources when modeling representative time periods.

**Storage inventory balance at beginning of each representative period**

The constraints in this section are used to approximate the behavior of long-duration energy storage technologies when approximating annual grid operations by modeling operations over representative periods. Previously, the state of charge balance for storage (as defined in ```storage_all()```) assumed that state of charge at the beginning and end of each representative period has to be the same. In other words, the amount of energy built up or consumed by storage technology $o$ in zone $z$ over the representative period $m$, $\Delta Q_{o,z,m} = 0$. This assumption implicitly excludes the possibility of transferring energy from one representative period to the other which could be cost-optimal when the capital cost of energy storage capacity is relatively small. To model long-duration energy storage using representative periods, we replace the state of charge equation, such that the first term on the right hand side accounts for change in storage inventory associated with representative period $m$ ($\Delta Q_{o,z,m}$), which could be positive (net accumulation) or negative (net reduction).

```math
\begin{aligned}
& \Gamma_{o,z,(m-1)\times \tau^{period}+1 } =\left(1-\eta_{o,z}^{loss}\right)\times \left(\Gamma_{o,z,m\times \tau^{period}} -\Delta Q_{o,z,m}\right) - \notag \\
&\frac{1}{\eta_{o,z}^{discharge}}\Theta_{o,z,(m-1)\times \tau^{period}+1} + \eta_{o,z}^{charge}\Pi_{o,z,(m-1)\times \tau^{period}+1} \quad \forall o \in \mathcal{O}^{LDES}, z \in \mathcal{Z}, m \in \mathcal{M}
\end{aligned}
```

By definition $\mathcal{T}^{start}=\{\left(m-1\right) \times \tau^{period}+1 | m \in \mathcal{M}\}$, which implies that this constraint is defined for all values of $t \in T^{start}$.

**Storage inventory change input periods**

We need additional variables and constraints to approximate energy exchange between representative periods, while accounting for their chronological occurence in the original input time series data and the possibility that two representative periods may not be adjacent to each other (Fig. \ref{fig:LDESmodel}). To implement this, we introduce a new variable $Q_{o,z, n}$ that models inventory of storage technology $o \in O$ in zone $z$ in each \textit{input} period $n \in \mathcal{N}$. Additionally we define a function mapping, $f: n \rightarrow m$, that uniquely maps each input period $n$ to its corresponding representative period $m$. This mapping is available as an output of the process used to identify representative periods (E.g. k-means clustering \cite{Mallapragada2018}).

\begin{figure}[h]
\caption{Modeling inter-period energy exchange via long-duration storage when using representative period temporal resolution to approximate annual grid operations}
\includegraphics[width=\textwidth]{LDES_approach.png}
\end{figure}

The following two equations define the storage inventory at the beginning of each input period $n+1$ as the sum of storage inventory at begining of previous input period $n$ plus change in storage inventory for that period. The latter is approximated by the change in storage inventory in the corresponding representative period, identified per the mapping $f(n)$.  The second constraint relates the storage level of the last input period, $|N|$, with the storage level at the beginning of the first input period. Finally, if the input period is also a representative period, then a third constraint enforces that initial storage level estimated by the intra-period storage balance constraint should equal the initial storage level estimated from the inter-period storage balance constraints.

%note that $|N|$ refers to the last modeled period. Here,
```math
\begin{aligned}
& Q_{o,z,n+1} = Q_{o,z,n} + \Delta Q_{o,z,f(n)}
\quad \forall  o \in \mathcal{O}^{LDES}, z \in \mathcal{Z}, n \in \mathcal{N}\setminus\{|N|\}
\end{aligned}
```

```math
\begin{aligned}
& Q_{o,z,1} = Q_{o,z,|N|} + \Delta Q_{o,z,f(|N|)}
\quad \forall  o \in \mathcal{O}^{LDES}, z \in \mathcal{Z}, n = |N|
\end{aligned}
```

```math
\begin{aligned}
& Q_{o,z,n} =\Gamma_{o,z,f(n)\times \tau^{period}} - \Delta Q_{o,z,m}
\quad \forall  o \in \mathcal{O}^{LDES}, z \in \mathcal{Z}, n \in   \mathcal{N}^{rep},
\end{aligned}
```

Finally, the next constraint enforces that the initial storage level for each input period $n$ must be less than the installed energy capacity limit. This constraint ensures that installed energy storage capacity is consistent with the state of charge during both the operational time periods $t$ during each sample period $m$ as well as at the start of each chronologically ordered input period $n$ in the full annual time series.

```math
\begin{aligned}
    Q_{o,z,n} \leq \Delta^{total, energy}_{o,z}
\quad \forall n \in \mathcal{N}, o \in \mathcal{O}^{LDES}
\end{aligned}
```
"""
function long_duration_storage(EP::Model, inputs::Dict)

	println("Long Duration Storage Module")

	dfGen = inputs["dfGen"]

	G = inputs["G"]     # Number of resources (generators, storage, DR, and DERs)
	T = inputs["T"]     # Number of time steps (hours)
	Z = inputs["Z"]     # Number of zones
	REP_PERIOD = inputs["REP_PERIOD"]     # Number of representative periods

	STOR_ALL = inputs["STOR_ALL"]
	START_SUBPERIODS = inputs["START_SUBPERIODS"]

	hours_per_subperiod = inputs["hours_per_subperiod"] #total number of hours per subperiod

	dfPeriodMap = inputs["Period_Map"] # Dataframe that maps modeled periods to representative periods
	NPeriods = size(inputs["Period_Map"])[1] # Number of modeled periods

	MODELED_PERIODS_INDEX = 1:NPeriods
	REP_PERIODS_INDEX = MODELED_PERIODS_INDEX[dfPeriodMap[!,:Rep_Period] .== MODELED_PERIODS_INDEX]

	### Variables ###

	# Variables to define inter-period energy transferred between modeled periods

	# State of charge of storage at beginning of each modeled period n
	@variable(EP, vSOCw[y in STOR_ALL, n in MODELED_PERIODS_INDEX] >= 0)

	# Build up in storage inventory over each representative period w
	# Build up inventory can be positive or negative
	@variable(EP, vdSOC[y in STOR_ALL, w=1:REP_PERIOD])

	### Constraints ###

	# Links last time step with first time step, ensuring position in hour 1 is within eligible change from final hour position
	# Modified initial state of storage for long-duration storage - initialize wth value carried over from last period
	# Alternative to cSoCBalStart constraint which is included when not modeling operations wrapping and long duration storage
	# Note: tw_min = hours_per_subperiod*(w-1)+1; tw_max = hours_per_subperiod*w
	@constraint(EP, cSoCBalLongDurationStorageStart[w=1:REP_PERIOD, y in STOR_ALL],
				    EP[:vS][y,hours_per_subperiod*(w-1)+1] == (1-dfGen[!,:Self_Disch][y])*(EP[:vS][y,hours_per_subperiod*w]-vdSOC[y,w])-(1/dfGen[!,:Eff_Down][y]*EP[:vP][y,hours_per_subperiod*(w-1)+1])+(dfGen[!,:Eff_Up][y]*EP[:vCHARGE][y,hours_per_subperiod*(w-1)+1]))

	# Storage at beginning of period w = storage at beginning of period w-1 + storage built up in period w (after n representative periods)
	## Multiply storage build up term from prior period with corresponding weight
	@constraint(EP, cSoCBalLongDurationStorageInterior[y in STOR_ALL, r in MODELED_PERIODS_INDEX[1:(end-1)]],
					vSOCw[y,r+1] == vSOCw[y,r] + vdSOC[y,dfPeriodMap[!,:Rep_Period_Index][r]])

	## Last period is linked to first period
	@constraint(EP, cSoCBalLongDurationStorageEnd[y in STOR_ALL, r in MODELED_PERIODS_INDEX[end]],
					vSOCw[y,1] == vSOCw[y,r] + vdSOC[y,dfPeriodMap[!,:Rep_Period_Index][r]])

	# Storage at beginning of each modeled period cannot exceed installed energy capacity
	@constraint(EP, cSoCBalLongDurationStorageUpper[y in STOR_ALL, r in MODELED_PERIODS_INDEX],
					vSOCw[y,r] <= EP[:eTotalCapEnergy][y])

	# Initial storage level for representative periods must also adhere to sub-period storage inventory balance
	# Initial storage = Final storage - change in storage inventory across representative period
	@constraint(EP, cSoCBalLongDurationStorageSub[y in STOR_ALL, r in REP_PERIODS_INDEX],
					vSOCw[y,r] == EP[:vS][y,hours_per_subperiod*dfPeriodMap[!,:Rep_Period_Index][r]] - vdSOC[y,dfPeriodMap[!,:Rep_Period_Index][r]])

	return EP
end
