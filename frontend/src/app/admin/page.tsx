import AdminPage from "@/components/admin/AdminPage";
import { UserProvider } from "@/lib/UserContext";

export default function Admin() {
  return (
    <UserProvider>
      <AdminPage />
    </UserProvider>
  );
}
