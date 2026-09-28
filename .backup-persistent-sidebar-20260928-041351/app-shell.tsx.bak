import { MobileNav } from "@/components/mobile-nav";
import { Sidebar } from "@/components/sidebar";
import { TopBar } from "@/components/top-bar";

export function AppShell({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen bg-[#080a0f] text-zinc-100">
      <div className="mx-auto flex min-h-screen max-w-[1900px]">
        <Sidebar />

        <div className="min-w-0 flex-1">
          <TopBar />
          <main className="min-w-0 pb-24 lg:pb-0">
            {children}
          </main>
        </div>

        <MobileNav />
      </div>
    </div>
  );
}
