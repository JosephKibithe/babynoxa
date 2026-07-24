import { fireEvent,render,screen } from "@testing-library/react";
import { describe,expect,it } from "vitest";
import { demoBackend,backend } from "../src/api.js";
import { ProjectCard,Shell } from "../src/components.js";
import { CreatePage } from "../src/pages/CreatePage.js";
import { validateMetadata } from "../src/metadata.js";
import { WalletProvider } from "../src/wallet.js";

describe("frontend components",()=>{
  it("renders lifecycle state and market progress",async()=>{const project=(await demoBackend.launch("1")).project;const{rerender}=render(<ProjectCard project={project}/>);expect(screen.getByText("Curve live")).toBeInTheDocument();project.lifecycle="graduated";rerender(<ProjectCard project={project}/>);expect(screen.getByText("AMM live")).toBeInTheDocument()});
  it("labels inputs and exposes validation before metadata preparation",()=>{render(<WalletProvider demo><CreatePage client={{...backend,prepareMetadata:demoBackend.prepareMetadata}} demo/></WalletProvider>);fireEvent.click(screen.getByRole("button",{name:"Create launch"}));expect(screen.getByRole("textbox",{name:/Token name/})).toBeInTheDocument();expect(screen.getByText("Use 1–32 characters.")).toHaveAttribute("role","alert");expect(screen.getByLabelText(/Preflight a local image/)).toHaveAttribute("accept","image/png,image/jpeg,image/webp,image/gif")});
  it("does not expose administration in the public navigation",()=>{render(<WalletProvider demo><Shell><p>Public page</p></Shell></WalletProvider>);expect(screen.queryByRole("link",{name:"Admin"})).not.toBeInTheDocument()});
  it("accepts omitted image and website while validating supplied URLs",()=>{const base={name:"No Media",symbol:"NONE",description:"",image:"",website:"",twitter:"",telegram:"",discord:""};expect(validateMetadata(base)).toEqual({});expect(validateMetadata({...base,image:"http://example.com/a.png"}).image).toBeDefined();expect(validateMetadata({...base,website:"not-a-url"}).website).toBeDefined()});
});
