import Dashboard from "@/components/dashboard/Dashboard";
import { UserProvider } from "@/lib/UserContext";

export default function Home() {
  return (
    <UserProvider>
      <Dashboard />
    </UserProvider>
  );
}
