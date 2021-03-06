package org.springframework.data.neo4j.support.mapping;

import org.springframework.data.neo4j.mapping.Neo4jPersistentEntity;

/**
 * @author mh
 * @since 19.10.14
 */
public interface EntityIndexCreator {
    void ensureEntityIndexes(Neo4jPersistentEntity<?> entity);
}
