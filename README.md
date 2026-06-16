# PowerMetrics
An easy to use Intel Power Gadget style power monitor. Quick features: 
- **Passwordless**: uses IOKit bindings instead of Mx Power Gadget's `powermetrics` which can cause kernel panics from certain dongles
- **Lightweight**: uses a similar or less CPU % compared to MxPG
- **Accurate**: raw IOKit power and frequency instead of MxPG's scale-down multiplier based on utilization
- **Familiar**: same clean frequency band drawing style as Intel PG
- **Customizable**: able to change the polling rate and graph capacity unlike MxPG
- **Open source**: contrary to MxPG

Supports M5-class chips natively (P/E/S clusters), with support for other generations coming. Mainly built for personal use!

### Demo
<img width="2129" height="1964" alt="PowerMetrics demo" src="https://github.com/user-attachments/assets/fbdab781-2df4-41d1-9a41-311913affdff" />
