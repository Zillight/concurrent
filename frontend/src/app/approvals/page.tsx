import ApprovalsPage from "@/components/approvals/ApprovalsPage";
import { UserProvider } from "@/lib/UserContext";

export default function Approvals() {
  return (
    <UserProvider>
      <ApprovalsPage />
    </UserProvider>
  );
}
