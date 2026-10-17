Journey bar between two waypoint codes with a glowing diamond marker. Pass `at` instead for a Ship holding at one waypoint (bar drains as countdown).

```jsx
<RouteBar from="F47" to="E45" progress={0.6} />
<RouteBar at="C41" progress={0.3} color="var(--status-waiting)" />
```
