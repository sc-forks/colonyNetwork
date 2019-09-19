/* globals artifacts */

import chai from "chai";
import bnChai from "bn-chai";
import { soliditySha3 } from "web3-utils";

import {
  WAD,
  ROOT_ROLE,
  ARCHITECTURE_ROLE,
  ARCHITECTURE_SUBDOMAIN_ROLE,
  FUNDING_ROLE,
  ADMINISTRATION_ROLE,
  INITIAL_FUNDING,
  SPECIFICATION_HASH
} from "../../helpers/constants";
import { checkErrorRevert } from "../../helpers/test-helper";
import { setupEtherRouter } from "../../helpers/upgradable-contracts";
import { setupColonyNetwork, setupMetaColonyWithLockedCLNYToken, setupRandomColony, fundColonyWithTokens } from "../../helpers/test-data-generator";

const { expect } = chai;
chai.use(bnChai(web3.utils.BN));

const ExtensionManager = artifacts.require("ExtensionManager");
const OldRoles = artifacts.require("OldRoles");
const Resolver = artifacts.require("Resolver");

contract("Old Roles", accounts => {
  let colony;
  let token;
  let colonyNetwork;
  let extensionManager;
  let oldRolesExtension;

  const OLD_ROLES = soliditySha3("OldRoles");

  const FOUNDER = accounts[0];
  const USER1 = accounts[1];
  const USER2 = accounts[2];

  before(async () => {
    colonyNetwork = await setupColonyNetwork();
    const { metaColony } = await setupMetaColonyWithLockedCLNYToken(colonyNetwork);

    extensionManager = await ExtensionManager.new(metaColony.address);
    const oldRoles = await OldRoles.new();
    const oldRolesResolver = await Resolver.new();
    await setupEtherRouter("OldRoles", { OldRoles: oldRoles.address }, oldRolesResolver);
    await extensionManager.addExtension(OLD_ROLES, 0, oldRolesResolver.address, [ROOT_ROLE]);

    await colonyNetwork.initialiseReputationMining();
    await colonyNetwork.startNextCycle();
  });

  beforeEach(async () => {
    ({ colony, token } = await setupRandomColony(colonyNetwork));
    await fundColonyWithTokens(colony, token, INITIAL_FUNDING);

    await colony.setRootRole(extensionManager.address, true);
    await extensionManager.installExtension(OLD_ROLES, 0, colony.address, 0, 1, 0, 1);

    const extensionAddress = await extensionManager.getExtension(OLD_ROLES, 0, colony.address, 1);
    oldRolesExtension = await OldRoles.at(extensionAddress);
  });

  describe("old roles", async () => {
    it("should be able to transfer the 'founder' role", async () => {
      await oldRolesExtension.setFounderRole(USER1);

      let hasRole = await colony.hasUserRole(USER1, 1, FUNDING_ROLE);
      expect(hasRole).to.be.true;
      hasRole = await colony.hasUserRole(USER1, 1, ADMINISTRATION_ROLE);
      expect(hasRole).to.be.true;
      hasRole = await colony.hasUserRole(USER1, 1, ARCHITECTURE_ROLE);
      expect(hasRole).to.be.true;
      hasRole = await colony.hasUserRole(USER1, 1, ARCHITECTURE_SUBDOMAIN_ROLE);
      expect(hasRole).to.be.true;
      hasRole = await colony.hasUserRole(USER1, 1, ROOT_ROLE);
      expect(hasRole).to.be.true;

      hasRole = await colony.hasUserRole(FOUNDER, 1, FUNDING_ROLE);
      expect(hasRole).to.be.false;
      hasRole = await colony.hasUserRole(FOUNDER, 1, ADMINISTRATION_ROLE);
      expect(hasRole).to.be.false;
      hasRole = await colony.hasUserRole(FOUNDER, 1, ARCHITECTURE_ROLE);
      expect(hasRole).to.be.false;
      hasRole = await colony.hasUserRole(FOUNDER, 1, ARCHITECTURE_SUBDOMAIN_ROLE);
      expect(hasRole).to.be.false;
      hasRole = await colony.hasUserRole(FOUNDER, 1, ROOT_ROLE);
      expect(hasRole).to.be.false;
    });

    it("should be able to assign 'admin' roles", async () => {
      await oldRolesExtension.setAdminRole(USER1, true);

      let hasRole = await colony.hasUserRole(USER1, 1, FUNDING_ROLE);
      expect(hasRole).to.be.true;
      hasRole = await colony.hasUserRole(USER1, 1, ADMINISTRATION_ROLE);
      expect(hasRole).to.be.true;
      hasRole = await colony.hasUserRole(USER1, 1, ARCHITECTURE_ROLE);
      expect(hasRole).to.be.true;
      hasRole = await colony.hasUserRole(USER1, 1, ARCHITECTURE_SUBDOMAIN_ROLE);
      expect(hasRole).to.be.true;
      hasRole = await colony.hasUserRole(USER1, 1, ROOT_ROLE);
      expect(hasRole).to.be.false;

      // Now they can do admin things
      await fundColonyWithTokens(colony, token, INITIAL_FUNDING);
      await colony.makeTask(1, 0, SPECIFICATION_HASH, 1, 0, 0, { from: USER1 });
      await colony.moveFundsBetweenPots(1, 0, 0, 1, 2, WAD, token.address, { from: USER1 });
      await colony.addDomain(1, 0, 1, { from: USER1 });

      // Make User2 an admin (subdomain only!)
      await colony.setAdministrationRole(1, 0, USER2, 2, true, { from: USER1 });
      await colony.makeTask(2, 0, SPECIFICATION_HASH, 2, 0, 0, { from: USER2 });
    });

    it("shouldnt be able to assign founder role without permission!", async () => {
      await checkErrorRevert(oldRolesExtension.setFounderRole(USER2, { from: USER1 }), "old-roles-caller-not-authorized");

      await oldRolesExtension.setFounderRole(USER1);
      await oldRolesExtension.setAdminRole(USER2, true, { from: USER1 });
    });

    it("shouldnt be able to assign admin role without permission!", async () => {
      await checkErrorRevert(oldRolesExtension.setAdminRole(USER2, true, { from: USER1 }), "old-roles-caller-not-authorized");

      await oldRolesExtension.setAdminRole(USER1, true);
      await oldRolesExtension.setAdminRole(USER2, true, { from: USER1 });
    });
  });
});
