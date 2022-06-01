using System.Text;

namespace AzureDeploymentWaterfall.Tree;

public static class TreeDrawer
{
    public static string Draw(Deployment tree)
    {
        return Draw(tree, false, "", "");
    }

    private static string Draw(Deployment tree, bool notLast, string previousTreeStart, string treeStart)
    {
        var sb = new StringBuilder();
        sb.AppendLine(
            $"{(treeStart == "" ? "" : $"{previousTreeStart}{(notLast ? "┃" : "┗")}━━")}⬤ {tree.ResourceGroup}/{tree.Name}");
        var childResources = new List<Resource>(tree.Resources);
        foreach (var childResource in tree.Resources)
        {
            var isResourceLast = childResource == childResources.Last() && !tree.ChildDeployments.Any();
            sb.AppendLine($"{treeStart}{(isResourceLast ? "┗" : "┃")}━━⬤ {childResource.Name}");
        }

        var childTrees = new List<Deployment>(tree.ChildDeployments.OrderBy(x => x.EndTime));
        foreach (var childTree in childTrees)
        {
            var moreSiblings = childTree != childTrees.Last();
            var nextTreeStart = moreSiblings ? $"{treeStart}┃  " : $"{treeStart}   ";
            sb.Append(Draw(childTree, moreSiblings, treeStart, nextTreeStart));
            if (moreSiblings)
            {
                sb.AppendLine($"{nextTreeStart.TrimEnd()}");
            }
        }

        return sb.ToString();
    }
}