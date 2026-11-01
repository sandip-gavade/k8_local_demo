import { useCallback, useEffect, useState } from "react";
import "./App.css";

// Same-origin: Vite proxies /api in dev; nginx (compose) / Ingress (K8s) route /api in prod.
const API = "/api/orders/";

export default function App() {
  const [orders, setOrders] = useState([]);
  const [raw, setRaw] = useState(null);
  const [error, setError] = useState(null);
  const [item, setItem] = useState("");
  const [quantity, setQuantity] = useState(1);

  const load = useCallback(async () => {
    try {
      const res = await fetch(API);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setRaw(data);
      setOrders(data.results);
      setError(null);
    } catch (e) {
      setError(e.message);
    }
  }, []);

  // Poll so you can watch Celery flip pending -> processed.
  useEffect(() => {
    load();
    const id = setInterval(load, 3000);
    return () => clearInterval(id);
  }, [load]);

  const submit = async (e) => {
    e.preventDefault();
    const res = await fetch(API, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ item, quantity: Number(quantity) }),
    });
    if (res.ok) {
      setItem("");
      load();
    } else {
      setError(`Create failed: HTTP ${res.status}`);
    }
  };

  return (
    <main>
      <h1>Orders</h1>
      {error && <p className="error">API error: {error}</p>}
      <form onSubmit={submit}>
        <input value={item} onChange={(e) => setItem(e.target.value)} placeholder="item" required />
        <input type="number" min="1" value={quantity} onChange={(e) => setQuantity(e.target.value)} />
        <button type="submit">Create order</button>
      </form>
      <table>
        <thead><tr><th>ID</th><th>Item</th><th>Qty</th><th>Status</th></tr></thead>
        <tbody>
          {orders.map((o) => (
            <tr key={o.id}><td>{o.id}</td><td>{o.item}</td><td>{o.quantity}</td><td className={o.status}>{o.status}</td></tr>
          ))}
        </tbody>
      </table>
      <h2>Raw API response</h2>
      <pre>{JSON.stringify(raw, null, 2)}</pre>
    </main>
  );
}
